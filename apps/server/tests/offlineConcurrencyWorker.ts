/**
 * 离线补录并发测试的子进程 worker：由 offlineConcurrency.test.ts 通过 tsx 拉起，
 * 每个 worker 是独立进程、独立的 better-sqlite3 连接（真实多进程写竞争，
 * 同一 Node 事件循环里发两个同步请求无法暴露 check-then-act 竞态）。
 *
 * 参数（argv）：libraryId clientOpId gateFile
 * 环境：DATABASE_URL 必须由父进程在启动前注入——静态 import 会先于本模块
 *       任何赋值执行，config.ts 在加载时就解析数据库路径。
 * 协议：就绪后输出 READY；轮询到 gateFile 出现即发起补录；输出一行 DONE <json>。
 */
import fs from 'node:fs';
import { applyOfflineOp } from '../src/services/offlineOps.js';
import { closeDb, getDb } from '../src/db.js';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main(): Promise<void> {
  const [, , libraryId, clientOpId, gateFile] = process.argv;

  getDb();
  process.stdout.write('READY\n');

  // 最多等 10s 放行信号
  for (let i = 0; i < 200; i += 1) {
    if (fs.existsSync(gateFile)) break;
    await sleep(50);
  }

  try {
    const out = applyOfflineOp(
      { clientOpId, opType: 'create_inspiration', payload: { title: '并发离线补录' } },
      libraryId,
    );
    process.stdout.write(`DONE ${JSON.stringify(out)}\n`);
  } catch (err) {
    process.stdout.write(`DONE ${JSON.stringify({ error: (err as Error).message ?? String(err) })}\n`);
  } finally {
    closeDb();
  }
}

void main();
