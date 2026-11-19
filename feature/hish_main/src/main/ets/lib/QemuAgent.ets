import { fileIo as fs } from '@kit.CoreFileKit'
import { socket } from '@kit.NetworkKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { util } from '@kit.ArkTS'

const DOMAIN = 0x0000

// QGA JSON-RPC 请求接口
interface QGARequest {
  execute: string
  arguments?: QGAArguments
  id: number
}

// QGA 参数类型
interface QGAArguments {
  mode?: string
  id?: number
  path?: string
  arg?: string[]
  'capture-output'?: boolean
  pid?: number
  signal?: number
}

// QGA JSON-RPC 响应接口  
interface QGAResponse {
  return?: QGAResponseData
  error?: QGAError
  id?: number
}

interface QGAError {
  class: string
  desc: string
}

interface PendingRequest {
  resolve: (value: QGAResponse | null) => void
  timer: number
}

interface QGAGuestMetrics {
  memoryInfo: Record<string, number> | null
  cpuStats: CpuStats | null
  sshRunning: boolean
}

// 基础响应类型
type QGAResponseData = Object;

// 具体业务接口定义
export interface QGANetworkAddress {
  'ip-address': string
  'ip-address-type': string
  prefix: number
}

export interface QGANetworkInterface {
  name: string
  'hardware-address'?: string
  'ip-addresses'?: QGANetworkAddress[]
  statistics?: Record<string, number>
}

export interface QGADiskInfo {
  name: string
  partition?: boolean
  dependencies?: string[]
  address?: Record<string, string>
  alias?: string
}

export interface QGAFilesystemInfo {
  name: string
  mountpoint: string
  type: string
  'used-bytes'?: number
  'total-bytes'?: number
  disk?: QGADiskInfo[]
}

export interface QGAVcpuInfo {
  'logical-id': number
  online: boolean
  'can-offline'?: boolean
}

export interface QGAExecStatus {
  exited: boolean
  'exit-code'?: number
  signal?: number
  'out-data'?: string
  'err-data'?: string
  'out-truncated'?: boolean
  'err-truncated'?: boolean
}

export interface QGAGuestInfo {
  version: string
  supported_commands: Record<string, boolean>[]
}

/**
 * QEMU Guest Agent 客户端
 * 通过 LocalSocket 与虚拟机内的 qemu-guest-agent 通信
 */
export class QemuAgent {
  private socketPath: string
  private client: socket.LocalSocket | null = null
  private requestId: number = 0
  private lineBuffer: string = ''
  private isConnected: boolean = false
  private pendingRequests: Map<number, PendingRequest> = new Map()

  constructor(socketPath: string) {
    this.socketPath = socketPath
  }

  /**
   * 连接到 QGA LocalSocket
   * [修复1.2] 连接前完全清理旧状态
   */
  async connect(): Promise<boolean> {
    // 先断开旧连接，确保干净状态
    await this.disconnect()

    try {
      if (!fs.accessSync(this.socketPath, fs.AccessModeType.EXIST)) {
        hilog.error(DOMAIN, 'QemuAgent', 'Socket 文件不存在: %{public}s', this.socketPath)
        return false
      }

      this.client = socket.constructLocalSocketInstance()
      this.lineBuffer = ''
      this.requestId = 0

      const address: socket.LocalAddress = {
        address: this.socketPath
      }
      const connectOptions: socket.LocalConnectOptions = {
        address,
        timeout: 1000  // 恢复至 1000ms，配合 VmController 的 Smart Skip 逻辑确保稳定性
      }

      await this.client.connect(connectOptions)

      // 设置消息接收监听器
      this.client.on('message', (value: socket.LocalSocketMessageInfo): void => {
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
        const message: string = decoder.decodeToString(new Uint8Array(value.message))
        this.handleIncoming(message)
      })

      // [修复] 监听错误事件
      this.client.on('error', (err: Error): void => {
        hilog.error(DOMAIN, 'QemuAgent', 'Socket 错误: %{public}s', JSON.stringify(err))
        this.isConnected = false
        this.rejectPending()
      })

      // [修复] 监听关闭事件
      this.client.on('close', (): void => {
        hilog.info(DOMAIN, 'QemuAgent', 'Socket 连接已关闭')
        this.isConnected = false
        this.rejectPending()
      })

      this.isConnected = true
      hilog.info(DOMAIN, 'QemuAgent', '已连接到 QGA: %{public}s', this.socketPath)

      // 连接后立即执行流同步，确保通信可靠
      const synced = await this.sync()
      if (!synced) {
        hilog.error(DOMAIN, 'QemuAgent', 'QGA 流同步失败，断开连接')
        await this.disconnect()
        return false
      }

      return true
    } catch (e) {
      hilog.error(DOMAIN, 'QemuAgent', '连接 QGA 失败: %{public}s', JSON.stringify(e))
      await this.disconnect()
      return false
    }
  }



  /**
   * 断开连接
   * [修复1.1] 完全清理：移除监听器、关闭连接、清空缓冲区
   */
  async disconnect(): Promise<void> {
    const client: socket.LocalSocket | null = this.client
    this.client = null
    this.isConnected = false
    this.lineBuffer = ''
    this.rejectPending()

    if (client) {
      try {
        client.off('message')
        client.off('error')
        client.off('close')
        await client.close()
      } catch (e) {
        // 忽略关闭错误
      }
      hilog.info(DOMAIN, 'QemuAgent', 'QGA 连接已断开')
    }
  }

  private rejectPending(): void {
    this.pendingRequests.forEach((pending: PendingRequest): void => {
      clearTimeout(pending.timer)
      pending.resolve(null)
    })
    this.pendingRequests.clear()
  }

  private handleIncoming(data: string): void {
    this.lineBuffer += data
    let newline = this.lineBuffer.indexOf('\n')
    while (newline !== -1) {
      const raw = this.lineBuffer.substring(0, newline)
      this.lineBuffer = this.lineBuffer.substring(newline + 1)
      this.handleLine(raw)
      newline = this.lineBuffer.indexOf('\n')
    }
  }

  private handleLine(raw: string): void {
    let line = raw.trim()
    const brace = line.indexOf('{')
    if (brace < 0) {
      return
    }
    if (brace > 0) {
      line = line.substring(brace)
    }

    let response: QGAResponse
    try {
      response = JSON.parse(line) as QGAResponse
    } catch (e) {
      return
    }
    if (response.id === undefined) {
      return
    }

    const pending = this.pendingRequests.get(response.id)
    if (!pending) {
      return
    }
    clearTimeout(pending.timer)
    this.pendingRequests.delete(response.id)
    pending.resolve(response)
  }

  /**
   * [修复1.4] 检查连接是否存活
   */
  isAlive(): boolean {
    return this.isConnected && this.client !== null
  }

  /**
   * 向 QGA 发送 JSON-RPC 命令
   * [修复1.3] 改进响应等待逻辑
   */
  private async sendCommand<T extends QGAResponseData>(command: string, args?: QGAArguments, waitForResponse: boolean = true, timeoutMs: number = 10000): Promise<T | null> {
    if (!this.client || !this.isConnected) {
      hilog.error(DOMAIN, 'QemuAgent', '发送命令失败：未连接到 QGA (命令: %{public}s)', command)
      return null
    }

    const currentId = ++this.requestId

    try {
      const request: QGARequest = {
        execute: command,
        arguments: args,
        id: currentId
      }
      const requestJson = JSON.stringify(request) + '\n'
      const encoder = util.TextEncoder.create()
      const buffer = encoder.encodeInto(requestJson)

      if (!waitForResponse) {
        await this.client.send({ data: buffer.buffer, encoding: 'utf-8' })
        hilog.debug(DOMAIN, 'QemuAgent', '发送命令(不等待): %{public}s (id=%{public}d)', command, currentId)
        return new Object() as T
      }

      const responsePromise = new Promise<T | null>((resolve: (value: T | null) => void) => {
        const timer = setTimeout(() => {
          if (this.pendingRequests.delete(currentId)) {
            hilog.error(DOMAIN, 'QemuAgent', '等待响应超时 (命令: %{public}s)', command)
            this.isConnected = false
            void this.disconnect()
            resolve(null)
          }
        }, timeoutMs)

        this.pendingRequests.set(currentId, {
          resolve: (response: QGAResponse | null): void => {
            if (!response) {
              resolve(null)
              return
            }
            if (response.error) {
              hilog.error(DOMAIN, 'QemuAgent', 'QGA 返回错误: %{public}s (命令: %{public}s)',
                JSON.stringify(response.error), command)
              resolve(null)
              return
            }
            resolve((response.return as T) || (new Object() as T))
          },
          timer
        })
      })

      await this.client.send({ data: buffer.buffer, encoding: 'utf-8' })
      hilog.debug(DOMAIN, 'QemuAgent', '发送命令: %{public}s (id=%{public}d)', command, currentId)
      return await responsePromise
    } catch (e) {
      const pending = this.pendingRequests.get(currentId)
      if (pending) {
        clearTimeout(pending.timer)
        this.pendingRequests.delete(currentId)
      }
      hilog.error(DOMAIN, 'QemuAgent', '执行命令异常: %{public}s (命令: %{public}s)', JSON.stringify(e), command)
      this.isConnected = false
      await this.disconnect()
      return null
    }
  }


  /**
   * 关机
   */
  async shutdown(): Promise<boolean> {
    const args: QGAArguments = { mode: 'powerdown' }
    const result = await this.sendCommand<Record<string, Object>>('guest-shutdown', args, false)
    return result !== null
  }

  /**
   * 重启
   */
  async reboot(): Promise<boolean> {
    const args: QGAArguments = { mode: 'reboot' }
    const result = await this.sendCommand<Record<string, Object>>('guest-shutdown', args, false)
    return result !== null
  }

  /**
   * 暂停（挂起到 RAM）
   */
  async suspend(): Promise<boolean> {
    const result = await this.sendCommand<Record<string, Object>>('guest-suspend-ram', undefined, false)
    return result !== null
  }

  /**
   * QGA 流同步 (guest-sync-delimited)
   * [优化] 在发送指令前发送 0xFF 字节以冲刷缓冲区，并发送随机 ID 以同步
   */
  private async sync(): Promise<boolean> {
    const syncToken = Math.floor(Math.random() * 2147483647)

    try {
      if (this.client) {
        // 1. 发送 0xFF 字符流引导，强制 Guest 端重置 JSON 解析器
        const resetBuffer = new ArrayBuffer(1)
        const view = new Uint8Array(resetBuffer)
        view[0] = 0xFF
        await this.client.send({ data: resetBuffer })
        // 稍作延迟让对端处理
        await new Promise<void>(resolve => setTimeout(resolve, 100))
      }

      // 2. 发送同步指令并验证返回 ID
      const response = await this.sendCommand<number>('guest-sync-delimited', { id: syncToken })
      return response !== null && response === syncToken
    } catch (e) {
      hilog.error(DOMAIN, 'QemuAgent', 'QGA 流同步异常: %{public}s', JSON.stringify(e))
      return false
    }
  }

  /**
   * Ping 检查 QGA 是否响应
   */
  async ping(): Promise<boolean> {
    const result = await this.sendCommand<Record<string, Object>>('guest-ping')
    return result !== null
  }

  /**
   * 获取虚拟机信息
   */
  async getInfo(): Promise<QGAGuestInfo | null> {
    return await this.sendCommand<QGAGuestInfo>('guest-info')
  }

  /**
   * 获取主机名
   */
  async getHostName(): Promise<string | null> {
    const result = await this.sendCommand<Record<string, string>>('guest-get-host-name')
    if (result && typeof result === 'object') {
      return result['host-name'] || null
    }
    return null
  }

  /**
   * 获取网络接口信息
   */
  async getNetworkInterfaces(): Promise<QGANetworkInterface[] | null> {
    const result = await this.sendCommand<QGANetworkInterface[]>('guest-network-get-interfaces')
    if (result && Array.isArray(result)) {
      return result
    }
    return null
  }

  /**
   * 获取文件系统信息
   */
  async getFilesystemInfo(): Promise<QGAFilesystemInfo[] | null> {
    const result = await this.sendCommand<QGAFilesystemInfo[]>('guest-get-fsinfo')
    if (result && Array.isArray(result)) {
      return result
    }
    return null
  }

  /**
   * 获取 vCPU 信息
   */
  async getVcpus(): Promise<QGAVcpuInfo[] | null> {
    const result = await this.sendCommand<QGAVcpuInfo[]>('guest-get-vcpus')
    if (result && Array.isArray(result)) {
      return result
    }
    return null
  }

  /**
   * 在虚拟机内执行命令
   */
  async exec(path: string, args?: string[]): Promise<number | null> {
    const execArgs: QGAArguments = {
      path: path,
      'capture-output': true
    }
    if (args) {
      execArgs.arg = args
    }
    const result = await this.sendCommand<Record<string, number>>('guest-exec', execArgs)
    if (result && typeof result === 'object') {
      return result['pid'] || null
    }
    return null
  }

  /**
   * 获取执行结果
   */
  async execStatus(pid: number): Promise<QGAExecStatus | null> {
    const args: QGAArguments = { pid }
    return await this.sendCommand<QGAExecStatus>('guest-exec-status', args)
  }

  /**
   * 执行命令并获取输出（便捷方法）
   * [优化] 增加超时清理逻辑，防止进程堆积
   */
  async execAndGetOutput(path: string, args?: string[], timeoutMs: number = 5000): Promise<string | null> {
    const pid = await this.exec(path, args)
    if (!pid) return null

    // 等待命令执行完成
    const startTime = Date.now()
    const pollDelays: number[] = [20, 20, 50, 100, 200]
    let pollIndex = 0
    while (Date.now() - startTime < timeoutMs) {
      const delay = pollDelays[Math.min(pollIndex, pollDelays.length - 1)]
      pollIndex += 1
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, delay))
      const status = await this.execStatus(pid)

      if (status && status.exited) {
        const outData = (status as Object as Record<string, Object>)['out-data'] as string
        if (outData) {
          // Base64 解码
          try {
            const decoder = util.TextDecoder.create('utf-8')
            const base64Helper = new util.Base64Helper()
            const decoded = base64Helper.decodeSync(outData)
            return decoder.decodeToString(decoded)
          } catch (e) {
            hilog.error(DOMAIN, 'QemuAgent', '解码输出失败: %{public}s', JSON.stringify(e))
          }
        }
        return ''
      }
    }

    // 超时清理：尝试杀死该进程
    hilog.warn(DOMAIN, 'QemuAgent', '命令执行超时 (PID: %{public}d)，尝试清理...', pid)
    await this.kill(pid)

    return null
  }

  /**
   * 杀死虚拟机内的进程
   */
  async kill(pid: number, signal: number = 15): Promise<boolean> {
    const args: QGAArguments = { pid, signal }
    const result = await this.sendCommand<Record<string, Object>>('guest-process-signal', args)
    return result !== null
  }

  /**
   * 获取内存信息（通过 /proc/meminfo）
   */
  async getMemoryInfo(): Promise<Record<string, number> | null> {
    // 使用 sh -c cat 以提高兼容性
    const output = await this.execAndGetOutput('/bin/sh', ['-c', 'cat /proc/meminfo'])
    if (!output) return null
    return this.parseMemoryInfo(output)
  }

  /**
   * 获取 CPU 统计信息（用于计算使用率）
   */
  async getCpuStats(): Promise<CpuStats | null> {
    // 使用 sh -c cat 以提高兼容性
    const output = await this.execAndGetOutput('/bin/sh', ['-c', 'cat /proc/stat'])
    if (!output) return null
    return this.parseCpuStats(output)
  }

  /**
   * 检查 SSH 是否运行
   */
  async isSshRunning(): Promise<boolean> {
    // 使用 sh -c 来执行 pgrep，利用 shell 的 PATH 查找命令，兼容性更好
    // 同时尝试 pgrep 和 pidof
    const output = await this.execAndGetOutput('/bin/sh', ['-c', 'pgrep sshd || pidof sshd'])
    return output !== null && output.trim().length > 0
  }

  private parseMemoryInfo(output: string): Record<string, number> {
    const result: Record<string, number> = {}
    const lines = output.split('\n')
    for (const line of lines) {
      const match = line.match(/^(\w+):\s+(\d+)\s*kB/)
      if (match) {
        result[match[1]] = parseInt(match[2]) * 1024
      }
    }
    return result
  }

  private parseCpuStats(output: string): CpuStats | null {
    const lines = output.split('\n')
    for (const line of lines) {
      if (line.startsWith('cpu ')) {
        const parts = line.split(/\s+/)
        if (parts.length >= 5) {
          const user = parseInt(parts[1])
          const nice = parseInt(parts[2])
          const system = parseInt(parts[3])
          const idle = parseInt(parts[4])
          const iowait = parts.length > 5 ? parseInt(parts[5]) : 0
          const irq = parts.length > 6 ? parseInt(parts[6]) : 0
          const softirq = parts.length > 7 ? parseInt(parts[7]) : 0
          const total = user + nice + system + idle + iowait + irq + softirq
          const stats: CpuStats = { total, idle }
          return stats
        }
      }
    }
    return null
  }

  async getGuestMetrics(): Promise<QGAGuestMetrics | null> {
    const output = await this.execAndGetOutput('/bin/sh', ['-c',
      'cat /proc/meminfo; echo __HISH_SEP__; cat /proc/stat; echo __HISH_SEP__; pgrep sshd || pidof sshd'])
    if (output === null) {
      return null
    }

    const parts = output.split('__HISH_SEP__')
    const metrics: QGAGuestMetrics = {
      memoryInfo: null,
      cpuStats: null,
      sshRunning: false
    }
    if (parts.length >= 1) {
      metrics.memoryInfo = this.parseMemoryInfo(parts[0])
    }
    if (parts.length >= 2) {
      metrics.cpuStats = this.parseCpuStats(parts[1])
    }
    if (parts.length >= 3) {
      metrics.sshRunning = parts[2].trim().length > 0
    }
    return metrics
  }
}

export interface CpuStats {
  total: number
  idle: number
}

export default QemuAgent
