import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { CircleDotDashed, Radio } from "lucide-react";
import type { ReactNode } from "react";

const healthy = new Set([
  "healthy",
  "open",
  "passed",
  "pass",
  "succeeded",
  "success",
  "active",
  "connected",
  "ready",
  "verified",
]);
const warning = new Set([
  "degraded",
  "queued",
  "preparing",
  "running",
  "starting",
  "recovering",
  "cancelling",
  "pending",
  "unconfigured",
  "unknown",
]);
const danger = new Set([
  "blocked",
  "unavailable",
  "offline",
  "failed",
  "failure",
  "cancelled",
  "timed_out",
  "quarantined",
  "rejected",
]);

export function StatusChip({
  state,
  label,
  pulse = false,
  className,
}: {
  state: string;
  label?: string;
  pulse?: boolean;
  className?: string;
}) {
  const normalized = state.toLowerCase();
  const tone = healthy.has(normalized)
    ? "success"
    : warning.has(normalized)
      ? "warning"
      : danger.has(normalized)
        ? "danger"
        : "neutral";
  return (
    <Badge
      variant="outline"
      data-tone={tone}
      className={cn(
        "status-chip gap-1.5 font-mono text-[10px] uppercase tracking-[0.12em]",
        className
      )}
    >
      <span
        className={cn(
          "status-dot",
          pulse && tone === "success" && "status-dot-pulse"
        )}
        aria-hidden="true"
      />
      {label ?? state.replaceAll("_", " ")}
    </Badge>
  );
}

export function TelemetryPanel({
  id,
  eyebrow,
  title,
  description,
  action,
  children,
  className,
}: {
  id?: string;
  eyebrow: string;
  title: string;
  description?: string;
  action?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section id={id} className={cn("telemetry-panel scroll-mt-6", className)}>
      <header className="telemetry-panel-header">
        <div className="min-w-0">
          <p className="telemetry-eyebrow">{eyebrow}</p>
          <h2 className="telemetry-title">{title}</h2>
          {description ? (
            <p className="mt-1 max-w-3xl text-sm leading-6 text-muted-foreground">
              {description}
            </p>
          ) : null}
        </div>
        {action ? <div className="shrink-0">{action}</div> : null}
      </header>
      <div className="telemetry-panel-body">{children}</div>
    </section>
  );
}

export function MetricCell({
  label,
  value,
  detail,
  state = "neutral",
}: {
  label: string;
  value: ReactNode;
  detail?: ReactNode;
  state?: "neutral" | "success" | "warning" | "danger" | "violet";
}) {
  return (
    <div className="metric-cell" data-tone={state}>
      <p className="metric-label">{label}</p>
      <div className="metric-value">{value}</div>
      {detail ? <div className="metric-detail">{detail}</div> : null}
    </div>
  );
}

export function EmptyTelemetry({
  title,
  detail,
}: {
  title: string;
  detail: string;
}) {
  return (
    <div className="flex min-h-36 flex-col items-center justify-center rounded-xl border border-dashed border-border/80 bg-background/25 p-6 text-center">
      <CircleDotDashed className="mb-3 h-6 w-6 text-muted-foreground" />
      <p className="text-sm font-medium text-foreground">{title}</p>
      <p className="mt-1 max-w-md text-xs leading-5 text-muted-foreground">
        {detail}
      </p>
    </div>
  );
}

export function LiveIndicator({ label = "Live polling" }: { label?: string }) {
  return (
    <div className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.14em] text-muted-foreground">
      <Radio className="h-3.5 w-3.5 text-primary" aria-hidden="true" />
      <span>{label}</span>
    </div>
  );
}

export function formatTimestamp(value: number | null | undefined) {
  if (!value) return "—";
  return new Date(value).toLocaleString();
}

export function formatElapsed(start: number | null, end?: number | null) {
  if (!start) return "—";
  const seconds = Math.max(0, Math.floor(((end ?? Date.now()) - start) / 1000));
  const minutes = Math.floor(seconds / 60);
  return `${minutes.toString().padStart(2, "0")}:${(seconds % 60)
    .toString()
    .padStart(2, "0")}`;
}

export function formatBytes(value: number) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 ** 2) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 ** 2).toFixed(1)} MiB`;
}
