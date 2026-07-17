import { readFile } from 'node:fs/promises'
import path from 'node:path'

export interface CountySummary {
  slug: string
  name: string
  members: number | null
  selection_method: string | null
}

export interface CountyDetail extends CountySummary {
  meeting_schedule: string | null
  body_html: string
}

// astro build and vitest both run with cwd = web/, so this resolves to
// web/public/data — the generator's output directory.
const DEFAULT_DATA_DIR = path.join(process.cwd(), 'public', 'data')

async function readJson<T>(filePath: string): Promise<T> {
  let raw: string
  try {
    raw = await readFile(filePath, 'utf-8')
  } catch (cause) {
    throw new Error(
      `Missing generated data file: ${filePath}. Run the generator first: cd generator && uv run build.py`,
      { cause },
    )
  }
  return JSON.parse(raw) as T
}

export function getCounties(dataDir: string = DEFAULT_DATA_DIR): Promise<CountySummary[]> {
  return readJson<CountySummary[]>(path.join(dataDir, 'counties.json'))
}

export function getCounty(slug: string, dataDir: string = DEFAULT_DATA_DIR): Promise<CountyDetail> {
  return readJson<CountyDetail>(path.join(dataDir, 'counties', `${slug}.json`))
}
