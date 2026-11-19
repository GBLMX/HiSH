import { fileIo as fs } from '@kit.CoreFileKit'


export async function readQcow2VirtualSizeAsync(filePath: string): Promise<number> {
  try {
    const f = await fs.open(filePath, fs.OpenMode.READ_ONLY)
    try {
      const HEADER_SIZE = 32
      const buffer = new ArrayBuffer(HEADER_SIZE)
      const bytesRead = await fs.read(f.fd, buffer, { offset: 0, length: HEADER_SIZE })
      if (bytesRead < HEADER_SIZE) {
        return 0
      }
      const dataView = new DataView(buffer)
      return Number(dataView.getBigInt64(24, false))
    } finally {
      await fs.close(f)
    }
  } catch (e) {
    return 0
  }
}
