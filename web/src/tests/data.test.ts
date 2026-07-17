import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { getCounties, getCounty } from '../lib/data'

const FIXTURES = path.join(__dirname, 'fixtures', 'data')

describe('getCounties', () => {
  it('returns the parsed county summaries', async () => {
    const counties = await getCounties(FIXTURES)
    expect(counties).toEqual([
      { slug: 'testville', name: 'Testville', members: 5, selection_method: 'Appointed' },
    ])
  })

  it('fails with a run-the-generator hint when the data file is missing', async () => {
    await expect(getCounties(path.join(__dirname, 'nowhere'))).rejects.toThrow(
      /uv run build\.py/,
    )
  })
})

describe('getCounty', () => {
  it('returns the full county detail', async () => {
    const county = await getCounty('testville', FIXTURES)
    expect(county.meeting_schedule).toBe('First Tuesday monthly')
    expect(county.body_html).toBe('<p>Board overview.</p>')
  })
})
