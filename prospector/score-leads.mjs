// Part 1, steps 3–5: one Jev call per post (buying + pain + vendor together),
// 3 calls at a time, then keep buying >= 0.60 AND vendor < 0.50.
// Input:  data/posts.json
// Output: leads.csv (url, buying, pain, vendor)
//         data/scores.jsonl (every result, so a rerun skips posts already scored)
//         data/all-scored.csv, data/failed.csv
import { readFileSync, appendFileSync } from 'node:fs';
import { LEAD_QUESTIONS, KEEP_IF, CONCURRENCY, MAX_STATE_CHARS } from './config.mjs';
import { dataPath, jev, pool, readJsonl, requireKey, round, writeCsv } from './lib.mjs';

requireKey();

const posts = JSON.parse(readFileSync(dataPath('posts.json'), 'utf8'));
const scoresPath = dataPath('scores.jsonl');
const done = new Map(readJsonl(scoresPath).filter(s => s.ok).map(s => [s.id, s]));
const todo = posts.filter(p => !done.has(p.id));
console.log(`${posts.length} posts, ${done.size} already scored, ${todo.length} to score (${CONCURRENCY} at a time)`);

const stateFor = p =>
  `Subreddit: r/${p.subreddit}\nTitle: ${p.title}\n\n${p.body}`.slice(0, MAX_STATE_CHARS);

const failed = [];
let finished = 0;
const t0 = performance.now();
await pool(todo, CONCURRENCY, async post => {
  const r = await jev(stateFor(post), LEAD_QUESTIONS);
  finished++;
  if (r.ok) {
    const row = { id: post.id, ok: true, ...r.probs, ms: r.ms, cost: r.cost };
    appendFileSync(scoresPath, JSON.stringify(row) + '\n');
    done.set(post.id, row);
    console.log(`[${finished}/${todo.length}] buying ${round(r.probs.buying)} pain ${round(r.probs.pain)} vendor ${round(r.probs.vendor)}  ${post.title.slice(0, 70)}`);
  } else {
    failed.push({ url: post.url, error: r.error, attempts: r.attempts });
    console.log(`[${finished}/${todo.length}] FAILED after ${r.attempts} tries: ${r.error}  ${post.url}`);
  }
});

const all = posts
  .filter(p => done.has(p.id))
  .map(p => {
    const s = done.get(p.id);
    return { url: p.url, subreddit: p.subreddit, created: p.created, title: p.title,
      buying: round(s.buying), pain: round(s.pain), vendor: round(s.vendor), cost: s.cost };
  })
  .sort((a, b) => b.buying - a.buying);

const leads = all.filter(KEEP_IF);
writeCsv(new URL('./leads.csv', import.meta.url), ['url', 'buying', 'pain', 'vendor'], leads);
writeCsv(dataPath('all-scored.csv'), ['url', 'subreddit', 'created', 'title', 'buying', 'pain', 'vendor', 'cost'], all);
writeCsv(dataPath('failed.csv'), ['url', 'error', 'attempts'], failed);

const cost = all.reduce((sum, r) => sum + (Number(r.cost) || 0), 0);
console.log(`\nScored ${all.length}/${posts.length} posts in ${((performance.now() - t0) / 1000).toFixed(0)} s this run`);
console.log(`Leads kept (buying >= 0.60 and vendor < 0.50): ${leads.length} -> leads.csv`);
console.log(`Failed this run: ${failed.length}${failed.length ? ' -> data/failed.csv (rerun to retry them)' : ''}`);
console.log(`Gateway-reported cost of all scored posts: $${cost.toFixed(6)}`);
