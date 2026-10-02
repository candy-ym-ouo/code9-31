import { offlineOpSchema } from '@flil/shared';
import { z } from 'zod';
import { getDb, newId, nowIso, toJson, type SqliteDb } from '../db.js';
import { errors } from '../http/errors.js';
import { addTags, createInspiration, requireInspiration } from './inspirations.js';
import { recomputeHitRate } from './calibration.js';

export type OfflineOpInput = z.infer<typeof offlineOpSchema>;

export interface OfflineApplyResult {
  duplicate: boolean;
  code?: 'OFFLINE_OP_DUPLICATE';
  result: Record<string, unknown> | null;
}

/**
 * 离线补录（每个资料库独立、且恰好生效一次）。
 *
 * 两个必须防住的坑：
 * 1. 跨库返回旧结果：client_op_id 是各客户端本地生成的操作号，不同库之间没有
 *    协同。幂等判定必须带 library_id，唯一约束也是 (library_id, client_op_id)。
 * 2. 并发重复副作用：先 SELECT 再 INSERT 是 check-then-act，两个并发请求可能
 *    都判定为"不存在"，于是副作用（建卡 / 打标 / 回填）各执行一遍。这里在
 *    BEGIN IMMEDIATE 事务里完成「查重 → 执行副作用 → 落幂等记录」整段：
 *    写锁在事务开始即获取，同库同操作号的并发请求被数据库串行化，先到者执行，
 *    后到者在同一个事务视图里看到记录并直接返回原结果。
 */
export function applyOfflineOp(input: OfflineOpInput, libraryId: string): OfflineApplyResult {
  const db = getDb();

  const run = db.transaction((): OfflineApplyResult => {
    const existing = db
      .prepare('SELECT result FROM offline_op WHERE library_id = ? AND client_op_id = ?')
      .get(libraryId, input.clientOpId) as { result: string | null } | undefined;
    if (existing) {
      // 幂等成功：返回该库首次执行时存下的结果，而不是重新执行一遍副作用
      return {
        duplicate: true,
        code: 'OFFLINE_OP_DUPLICATE',
        result: existing.result ? (JSON.parse(existing.result) as Record<string, unknown>) : null,
      };
    }

    const result = executeOp(db, input, libraryId);

    db.prepare(
      'INSERT INTO offline_op (id, library_id, client_op_id, op_type, payload, result, applied_at, created_at) VALUES (?,?,?,?,?,?,?,?)',
    ).run(
      newId(),
      libraryId,
      input.clientOpId,
      input.opType,
      toJson(input.payload),
      toJson(result),
      nowIso(),
      nowIso(),
    );

    return { duplicate: false, result };
  });

  // immediate：立即拿保留写锁，避免两个事务都进入后再在写入时相撞
  return run.immediate();
}

function executeOp(db: SqliteDb, input: OfflineOpInput, libraryId: string): Record<string, unknown> {
  if (input.opType === 'create_inspiration') {
    const payload = z
      .object({ title: z.string().min(1).max(200), note: z.string().max(5000).nullable().optional() })
      .parse(input.payload);
    const id = createInspiration({
      libraryId,
      title: payload.title,
      note: payload.note ?? null,
    });
    return { inspirationId: id };
  }

  if (input.opType === 'tag') {
    const payload = z
      .object({ inspirationId: z.string().min(1), addTagIds: z.array(z.string()).default([]) })
      .parse(input.payload);
    requireInspiration(payload.inspirationId, libraryId);
    const added = addTags(payload.inspirationId, payload.addTagIds, 'bulk');
    return { inspirationId: payload.inspirationId, added };
  }

  if (input.opType === 'fill_result') {
    const payload = z
      .object({
        planId: z.string().min(1),
        hitLevel: z.enum(['hit', 'partial', 'miss']),
        missReasons: z.array(z.string()).default([]),
      })
      .parse(input.payload);
    const plan = db
      .prepare('SELECT * FROM shoot_plan WHERE id = ? AND library_id = ?')
      .get(payload.planId, libraryId) as Record<string, unknown> | undefined;
    if (!plan) throw errors.notFound('计划');
    const exists = db.prepare('SELECT id FROM shoot_result WHERE plan_id = ?').get(payload.planId);
    if (!exists) {
      db.prepare(
        `INSERT INTO shoot_result (id, library_id, plan_id, inspiration_id, hit_level, miss_reasons, filled_at, created_at)
         VALUES (?,?,?,?,?,?,?,?)`,
      ).run(
        newId(),
        libraryId,
        payload.planId,
        plan.inspiration_id as string,
        payload.hitLevel,
        toJson(payload.missReasons),
        nowIso(),
        nowIso(),
      );
      db.prepare("UPDATE shoot_plan SET status = 'done', updated_at = ? WHERE id = ?").run(nowIso(), payload.planId);
      recomputeHitRate(plan.inspiration_id as string);
    }
    return { planId: payload.planId, applied: true };
  }

  // note
  const payload = z.object({ inspirationId: z.string().min(1), note: z.string().max(5000) }).parse(input.payload);
  requireInspiration(payload.inspirationId, libraryId);
  db.prepare('UPDATE inspiration SET note = ?, updated_at = ? WHERE id = ?').run(
    payload.note,
    nowIso(),
    payload.inspirationId,
  );
  return { inspirationId: payload.inspirationId, updated: true };
}
