import { z } from "zod";
import {
  LIVE_ACTION_KINDS,
  LIVE_OBSERVATION_KINDS,
  idempotencyKeySchema,
  jobSubmissionSchema,
  quarantineClearSchema,
  quarantineSetSchema,
} from "../../shared/operator";
import { router } from "../_core/trpc";
import { ownerProcedure } from "../operator/owner";
import { operatorService } from "../operator/service";

const idSchema = z.string().trim().min(1).max(128);
const traceIdSchema = z.string().uuid();
export const liveCommandSchema = z
  .record(z.string().min(1).max(80), z.unknown())
  .superRefine((value, context) => {
    const bytes = Buffer.byteLength(JSON.stringify(value), "utf8");
    if (bytes > 32 * 1024) {
      context.addIssue({
        code: "custom",
        message: "QA command exceeds 32 KiB.",
      });
    }
  });

export const liveActionInputSchema = z
  .object({
    sessionId: idSchema,
    kind: z.enum(LIVE_ACTION_KINDS),
    command: liveCommandSchema.optional(),
  })
  .superRefine((value, context) => {
    if (value.kind === "qa_command" && !value.command) {
      context.addIssue({
        code: "custom",
        path: ["command"],
        message: "QA command JSON is required for qa_command.",
      });
    }
    if (value.kind !== "qa_command" && value.command) {
      context.addIssue({
        code: "custom",
        path: ["command"],
        message: "This action does not accept command JSON.",
      });
    }
  });

export const liveObservationInputSchema = z.object({
  sessionId: idSchema,
  kind: z.enum(LIVE_OBSERVATION_KINDS),
});

export const operatorRouter = router({
  overview: ownerProcedure.query(({ ctx }) =>
    operatorService.overview(ctx.user.id)
  ),
  jobs: router({
    list: ownerProcedure.query(({ ctx }) =>
      operatorService.listJobs(ctx.user.id)
    ),
    detail: ownerProcedure
      .input(z.object({ id: idSchema }))
      .query(({ ctx, input }) =>
        operatorService.jobDetail(ctx.user.id, input.id)
      ),
    log: ownerProcedure
      .input(z.object({ id: idSchema }))
      .query(({ ctx, input }) => operatorService.jobLog(ctx.user.id, input.id)),
    submit: ownerProcedure
      .input(jobSubmissionSchema)
      .mutation(({ ctx, input }) =>
        operatorService.submitJob(ctx.user.id, input)
      ),
    cancel: ownerProcedure
      .input(z.object({ id: idSchema }))
      .mutation(({ ctx, input }) =>
        operatorService.cancelJob(ctx.user.id, input.id)
      ),
  }),
  live: router({
    detail: ownerProcedure
      .input(z.object({ id: idSchema }))
      .query(({ ctx, input }) =>
        operatorService.liveSession(ctx.user.id, input.id)
      ),
    open: ownerProcedure
      .input(
        z.object({
          deviceUdid: z.string().min(24).max(40),
          idempotencyKey: idempotencyKeySchema,
        })
      )
      .mutation(({ ctx, input }) =>
        operatorService.openLiveSession(
          ctx.user.id,
          input.deviceUdid,
          input.idempotencyKey
        )
      ),
    action: ownerProcedure
      .input(liveActionInputSchema)
      .mutation(({ ctx, input }) =>
        operatorService.executeLiveAction(ctx.user.id, input)
      ),
    observe: ownerProcedure
      .input(liveObservationInputSchema)
      .mutation(({ ctx, input }) =>
        operatorService.captureLiveObservation(
          ctx.user.id,
          input.sessionId,
          input.kind
        )
      ),
    screenshot: ownerProcedure
      .input(z.object({ sessionId: idSchema }))
      .query(({ ctx, input }) =>
        operatorService.latestLiveScreenshot(ctx.user.id, input.sessionId)
      ),
  }),
  traces: router({
    list: ownerProcedure.query(() => operatorService.listTraces()),
    detail: ownerProcedure
      .input(z.object({ traceId: traceIdSchema }))
      .query(({ input }) => operatorService.traceDetail(input.traceId)),
  }),
  evidence: router({
    inventory: ownerProcedure
      .input(z.object({ traceId: traceIdSchema }))
      .query(({ ctx, input }) =>
        operatorService.evidenceInventory(ctx.user.id, input.traceId)
      ),
    prepare: ownerProcedure
      .input(z.object({ traceId: traceIdSchema }))
      .mutation(({ ctx, input }) =>
        operatorService.prepareEvidence(ctx.user.id, input.traceId)
      ),
    summary: ownerProcedure
      .input(z.object({ traceId: traceIdSchema }))
      .query(({ ctx, input }) =>
        operatorService.evidenceSummary(ctx.user.id, input.traceId)
      ),
  }),
  quarantine: router({
    set: ownerProcedure
      .input(quarantineSetSchema)
      .mutation(({ ctx, input }) =>
        operatorService.setQuarantine(ctx.user.id, input.mode, input.reason)
      ),
    clear: ownerProcedure
      .input(quarantineClearSchema)
      .mutation(({ ctx, input }) =>
        operatorService.clearQuarantine(ctx.user.id, input.acknowledgement)
      ),
  }),
});
