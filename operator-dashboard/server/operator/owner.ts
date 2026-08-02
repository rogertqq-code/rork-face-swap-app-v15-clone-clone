import { TRPCError } from "@trpc/server";
import { ENV } from "../_core/env";
import { protectedProcedure } from "../_core/trpc";

export const ownerProcedure = protectedProcedure.use(({ ctx, next }) => {
  if (
    !ENV.ownerOpenId ||
    ctx.user.role !== "admin" ||
    ctx.user.openId !== ENV.ownerOpenId
  ) {
    throw new TRPCError({
      code: "FORBIDDEN",
      message: "This operator console is restricted to the configured owner.",
    });
  }

  return next({ ctx: { ...ctx, user: ctx.user } });
});
