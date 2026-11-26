/**
 * The vision evaluation's report: one HTML page a person goes through photo by photo, marking what each model
 * misread. The page is static; the run's results are embedded as JSON and the marks stay in the browser.
 */
import { readFileSync } from 'node:fs';

const template = new URL('./vision-report.template.html', import.meta.url);

/**
 * `run` is what runEval returned, `summary` what summarize returned, and `src(photo)` gives each photo's address
 * relative to the report. Model output is embedded as data and shown as text, never as markup.
 */
export function renderReport({ runId, startedAt, models, run, summary, src }) {
  const data = {
    runId, startedAt, summary, models: models.map(({ name, model }) => ({ name, model })),
    photos: run.photos.map(photo => ({ name: photo.name, src: src(photo), width: photo.width, height: photo.height, orientation: photo.orientation,
      rows: photo.rows, results: Object.fromEntries(Object.entries(photo.results).map(([name, r]) => [name,
        r.ok ? { ok: true, ms: r.ms, reading: { legible: r.reading.legible, note: r.reading.note, items: r.reading.items.map(() => 0) } } : { ok: false, ms: r.ms, error: r.error }])) }))
  };
  // "<" is escaped so nothing a model wrote can close the script element.
  const json = JSON.stringify(data).replace(/</g, '\\u003c');
  return readFileSync(template, 'utf8').replace('__DATA__', () => json);
}
