import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Database from 'better-sqlite3';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

/**
 * 离线补录的"并发重复副作用"必须用真实多进程才能复现：
 * better-sqlite3 是同步驱动，同一 Node 事件循环里的两个 HTTP 请求无法在
 * check-then-act 之间交错。这里每个 worker 是独立进程 + 独立连接，
 * 用 gate 文件让它们同时发起同一操作号的补录。
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const workerFile = path.join(here, 'offlineConcurrencyWorker.ts');
const tsxBin = path.resolve(here, '../../../node_modules/tsx/dist/cli.mjs');

let tmpDir: string;
let dbFile: string;
let gateFile: string;

interface WorkerOutcome {
  duplicate?: boolean;
  code?: string;
  result?: { inspirationId?: string } | null;
  error?: string;
}

interface Worker {
  result: Promise<WorkerOutcome>;
  ready: Promise<void>;
}

function spawnWorker(libraryId: string, clientOpId: string): Worker {
  const child = spawn(process.execPath, [tsxBin, workerFile, libraryId, clientOpId, gateFile], {
    stdio: ['ignore', 'pipe', 'pipe'],
    // DATABASE_URL 必须在子进程启动前注入：config.ts 在静态 import 阶段就解析路径
    env: { ...process.env, DATABASE_URL: dbFile },
  });
  let stdout = '';
  let stderr = '';

  const result = new Promise<WorkerOutcome>((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('worker 超时未完成'));
    }, 25000);
    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      const line = stdout.split('\n').find((l) => l.startsWith('DONE '));
      if (!line) {
        reject(new Error(`worker 未返回结果 (exit=${code}): ${stderr}`));
        return;
      }
      try {
        resolve(JSON.parse(line.slice('DONE '.length)) as WorkerOutcome);
      } catch (err) {
        reject(new Error(`worker 结果解析失败: ${String(err)}: ${line}`));
      }
    });
  });

  const ready = new Promise<void>((resolve, reject) => {
    const onData = (chunk: Buffer) => {
      if (chunk.toString().includes('READY')) {
        child.stdout.off('data', onData);
        resolve();
      }
    };
    child.stdout.on('data', onData);
    child.on('exit', (code) => {
      if (code !== 0 && !stdout.includes('DONE ')) reject(new Error(`worker 启动失败 (exit=${code}): ${stderr}`));
    });
  });

  return { result, ready };
}

beforeAll(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'flil-offline-conc-'));
  dbFile = path.join(tmpDir, 'app.db');
  gateFile = path.join(tmpDir, 'gate');

  // 建库结构（按顺序跑迁移 SQL），再插入两个库（library.owner_id 有外键，连带占位用户）
  const db = new Database(dbFile);
  db.pragma('journal_mode = WAL');
  const sqlDir = path.resolve(here, '../sql');
  for (const f of fs.readdirSync(sqlDir).sort()) {
    db.exec(fs.readFileSync(path.join(sqlDir, f), 'utf8'));
  }
  const now = new Date().toISOString();
  for (const id of ['libA', 'libB']) {
    db.prepare('INSERT INTO "user" (id, email, password_hash, display_name, created_at, updated_at) VALUES (?,?,?,?,?,?)')
      .run(`u-${id}`, `${id}@conc.local`, 'x', id, now, now);
    db.prepare(
      'INSERT INTO library (id, name, owner_id, default_fuzz_level, tz, created_at, updated_at) VALUES (?,?,?,?,?,?,?)',
    ).run(id, id, `u-${id}`, 'g500', 'Asia/Shanghai', now, now);
  }
  db.close();
});

afterAll(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

describe('E9b 离线补录并发：每库独立且副作用仅一次', () => {
  it(
    '同库 4 个进程同操作号并发：1 次执行 + 3 次幂等命中，无唯一约束错误，副作用只落一条',
    async () => {
      const opId = 'op-concurrent-same-lib';
      const workers = Array.from({ length: 4 }, () => spawnWorker('libA', opId));
      await Promise.all(workers.map((w) => w.ready));

      fs.writeFileSync(gateFile, 'go');
      const outcomes = await Promise.all(workers.map((w) => w.result));

      expect(outcomes.filter((o) => o.error)).toEqual([]);
      const applied = outcomes.filter((o) => o.duplicate === false);
      const duplicated = outcomes.filter((o) => o.duplicate === true && o.code === 'OFFLINE_OP_DUPLICATE');
      expect(applied).toHaveLength(1);
      expect(duplicated).toHaveLength(3);
      const createdId = applied[0].result?.inspirationId;
      expect(createdId).toBeTruthy();
      // 所有幂等返回都指向同一张卡（先到者的结果）
      for (const d of duplicated) {
        expect(d.result?.inspirationId).toBe(createdId);
      }

      const db = new Database(dbFile);
      const opRows = db
        .prepare('SELECT COUNT(*) AS n FROM offline_op WHERE library_id = ? AND client_op_id = ?')
        .get('libA', opId) as { n: number };
      const cards = db
        .prepare('SELECT COUNT(*) AS n FROM inspiration WHERE library_id = ?')
        .get('libA') as { n: number };
      db.close();
      expect(opRows.n).toBe(1);
      expect(cards.n).toBe(1);
    },
    30000,
  );

  it(
    '两个库各 2 个进程同一操作号并发：每库各自执行一次，互不串结果',
    async () => {
      fs.rmSync(gateFile, { force: true });
      const opId = 'op-concurrent-cross-lib';
      const a = [0, 1].map(() => spawnWorker('libA', opId));
      const b = [0, 1].map(() => spawnWorker('libB', opId));
      await Promise.all([...a, ...b].map((w) => w.ready));

      fs.writeFileSync(gateFile, 'go');
      const [ra, rb] = await Promise.all([
        Promise.all(a.map((w) => w.result)),
        Promise.all(b.map((w) => w.result)),
      ]);

      for (const outcomes of [ra, rb]) {
        expect(outcomes.filter((o) => o.error)).toEqual([]);
        const applied = outcomes.filter((o) => o.duplicate === false);
        const duplicated = outcomes.filter((o) => o.duplicate === true);
        expect(applied).toHaveLength(1);
        expect(duplicated).toHaveLength(1);
        // 本库的幂等重试必须返回本库首执结果
        expect(duplicated[0].result?.inspirationId).toBe(applied[0].result?.inspirationId);
      }
      const idA = ra.find((o) => o.duplicate === false)?.result?.inspirationId;
      const idB = rb.find((o) => o.duplicate === false)?.result?.inspirationId;
      expect(idA).toBeTruthy();
      expect(idB).toBeTruthy();
      expect(idA).not.toBe(idB);

      const db = new Database(dbFile);
      const opsPerLib = (lib: string) =>
        (
          db
            .prepare('SELECT COUNT(*) AS n FROM offline_op WHERE library_id = ? AND client_op_id = ?')
            .get(lib, opId) as { n: number }
        ).n;
      const cardsPerLib = (lib: string) =>
        (db.prepare('SELECT COUNT(*) AS n FROM inspiration WHERE library_id = ?').get(lib) as { n: number }).n;
      expect(opsPerLib('libA')).toBe(1);
      expect(opsPerLib('libB')).toBe(1);
      expect(cardsPerLib('libA')).toBe(2); // 上一个用例 1 条 + 本用例 1 条
      expect(cardsPerLib('libB')).toBe(1);
      db.close();
    },
    30000,
  );
});
