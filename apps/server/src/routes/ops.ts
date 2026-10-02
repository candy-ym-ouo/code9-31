import fs from 'node:fs';
import { Router } from 'express';
import { z } from 'zod';
import { offlineOpSchema } from '@flil/shared';
import { getDb, nowIso } from '../db.js';
import { config } from '../config.js';
import { ah, ok } from '../http/respond.js';
import { authenticate, requireOwner } from '../http/middleware.js';
import { ctxOf } from '../http/context.js';
import { createBackup, exportAll, listBackups, restoreBackup } from '../services/backup.js';
import { subscribe } from '../services/events.js';
import { applyOfflineOp } from '../services/offlineOps.js';

export const opsRouter = Router();

/** 健康检查：不需要登录，用于运维与冒烟脚本 */
opsRouter.get(
  '/health',
  ah(async (_req, res) => {
    const db = getDb();
    let dbOk = true;
    try {
      db.prepare('SELECT 1 AS x').get();
    } catch {
      dbOk = false;
    }
    const dirs = Object.fromEntries(
      Object.entries({
        uploads: config.uploadDir,
        thumbs: config.thumbDir,
        share: config.shareDir,
        backups: config.backupDir,
      }).map(([k, dir]) => {
        try {
          fs.accessSync(dir, fs.constants.W_OK);
          return [k, 'ok'];
        } catch {
          return [k, 'unwritable'];
        }
      }),
    );

    ok(res, {
      ok: dbOk && Object.values(dirs).every((v) => v === 'ok'),
      db: dbOk ? 'ok' : 'error',
      dirs,
      weatherProvider: config.weatherProvider,
      weatherDegraded: config.weatherProvider === 'off',
      shareEnabled: config.enableShare,
      version: '1.0.0',
      time: nowIso(),
    });
  }),
);

/**
 * 注意：Router.use() 对「所有经过该 router 的请求」生效，
 * 所以这里必须显式放过公开路径，否则后面的公开分享路由永远收不到请求。
 */
opsRouter.use((req, res, next) => {
  if (req.path.startsWith('/share/')) return next();
  return authenticate()(req, res, next);
});

/** 图片与数据库一致性巡检：找出缺失文件与孤儿记录 */
opsRouter.get(
  '/health/verify-assets',
  ah(async (req, res) => {
    const ctx = ctxOf(req);
    const rows = getDb().prepare('SELECT id, file_path, thumb_path FROM asset WHERE library_id = ?').all(
      ctx.libraryId,
    ) as { id: string; file_path: string; thumb_path: string | null }[];
    const missing = rows.filter((r) => !fs.existsSync(r.file_path)).map((r) => r.id);
    const missingThumbs = rows.filter((r) => r.thumb_path && !fs.existsSync(r.thumb_path)).map((r) => r.id);
    ok(res, { total: rows.length, missing, missingThumbs });
  }),
);

opsRouter.post(
  '/backup',
  ah(async (_req, res) => {
    const info = await createBackup();
    ok(res, info, 201);
  }),
);

opsRouter.get(
  '/backup/list',
  ah(async (_req, res) => {
    ok(res, { items: listBackups() });
  }),
);

opsRouter.post(
  '/backup/restore',
  ah(async (req, res) => {
    requireOwner(req);
    const input = z.object({ name: z.string().min(1), confirm: z.boolean() }).parse(req.body);
    const result = await restoreBackup(input.name, input.confirm);
    ok(res, { ...result, note: '还原前已自动备份当前状态，可回滚到该安全备份。' });
  }),
);

opsRouter.get(
  '/export/inspirations.json',
  ah(async (req, res) => {
    requireOwner(req);
    const ctx = ctxOf(req);
    const data = exportAll(ctx.libraryId);
    res.setHeader('content-disposition', 'attachment; filename="inspirations-export.json"');
    res.setHeader('content-type', 'application/json');
    res.send(JSON.stringify(data, null, 2));
  }),
);

/**
 * 离线补录：(library_id, client_op_id) 唯一约束 + 单事务保证幂等。
 * - 操作号按库隔离：不同资料库各自生成同一 client_op_id 互不影响，
 *   每个库拿到的都是本库首次执行的结果；
 * - 重复提交返回 200 与该库的原结果（OFFLINE_OP_DUPLICATE 属于幂等成功，
 *   不是错误）；
 * - 并发重复提交由 IMMEDIATE 事务串行化，副作用只执行一次。
 */
opsRouter.post(
  '/offline/apply',
  ah(async (req, res) => {
    const ctx = ctxOf(req);
    const input = offlineOpSchema.parse(req.body);
    const out = applyOfflineOp(input, ctx.libraryId);
    ok(res, out, out.duplicate ? 200 : 201);
  }),
);

/** SSE：图片处理完成、窗口判定变化、提醒状态变化 */
opsRouter.get('/events/stream', (req, res) => {
  const ctx = ctxOf(req);
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  });
  res.write(`event: hello\ndata: ${JSON.stringify({ libraryId: ctx.libraryId })}\n\n`);
  const unsubscribe = subscribe(ctx.libraryId, res);
  const keepAlive = setInterval(() => res.write(': keep-alive\n\n'), 25000);
  req.on('close', () => {
    clearInterval(keepAlive);
    unsubscribe();
  });
});
