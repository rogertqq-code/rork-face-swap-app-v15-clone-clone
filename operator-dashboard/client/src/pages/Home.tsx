import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Textarea } from "@/components/ui/textarea";
import {
  EmptyTelemetry,
  formatBytes,
  formatElapsed,
  formatTimestamp,
  LiveIndicator,
  MetricCell,
  StatusChip,
  TelemetryPanel,
} from "@/components/operator/OperatorPrimitives";
import { trpc } from "@/lib/trpc";
import {
  LIVE_ACTION_KINDS,
  LIVE_OBSERVATION_KINDS,
  OPERATOR_POLL_INTERVALS_MS,
  OPERATOR_SCENARIOS,
  QUARANTINE_CLEAR_ACKNOWLEDGEMENT,
  QUARANTINE_MODES,
  type LiveActionKind,
  type LiveObservationKind,
  type OperatorScenario,
  type QuarantineMode,
} from "@shared/operator";
import {
  Activity,
  AlertTriangle,
  Archive,
  Ban,
  Camera,
  Check,
  ChevronRight,
  CircleStop,
  Clock3,
  Copy,
  Download,
  ExternalLink,
  FileCheck2,
  Fingerprint,
  GitBranch,
  HardDriveDownload,
  KeyRound,
  Loader2,
  LockKeyhole,
  Play,
  RadioTower,
  RefreshCw,
  ShieldAlert,
  ShieldCheck,
  Smartphone,
  TerminalSquare,
  WifiOff,
  X,
} from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

function newIdempotencyKey() {
  return crypto.randomUUID();
}

export default function Home() {
  const [scenario, setScenario] = useState<OperatorScenario>("canary");
  const [deviceUdid, setDeviceUdid] = useState("");
  const [retryCount, setRetryCount] = useState("0");
  const [idempotencyKey, setIdempotencyKey] = useState(newIdempotencyKey);
  const [selectedTraceId, setSelectedTraceId] = useState<string | null>(null);
  const [quarantineMode, setQuarantineMode] =
    useState<QuarantineMode>("manual");
  const [quarantineReason, setQuarantineReason] = useState("");
  const [clearAcknowledgement, setClearAcknowledgement] = useState("");
  const [liveActionKind, setLiveActionKind] =
    useState<LiveActionKind>("query_app_state");
  const [liveObservationKind, setLiveObservationKind] =
    useState<LiveObservationKind>("screenshot");
  const [qaCommandJson, setQaCommandJson] = useState("{}");

  const overview = trpc.operator.overview.useQuery(undefined, {
    refetchInterval: OPERATOR_POLL_INTERVALS_MS.overview,
    refetchOnWindowFocus: true,
  });
  const jobs = trpc.operator.jobs.list.useQuery(undefined, {
    refetchInterval: OPERATOR_POLL_INTERVALS_MS.index,
  });
  const traces = trpc.operator.traces.list.useQuery(undefined, {
    refetchInterval: OPERATOR_POLL_INTERVALS_MS.index,
  });
  const activeJobId = overview.data?.activeJob?.id ?? null;
  const activeLiveSessionId = overview.data?.activeLiveSession?.id ?? null;
  const jobLog = trpc.operator.jobs.log.useQuery(
    { id: activeJobId ?? "" },
    {
      enabled: Boolean(activeJobId),
      refetchInterval: OPERATOR_POLL_INTERVALS_MS.active,
    }
  );
  const liveSession = trpc.operator.live.detail.useQuery(
    { id: activeLiveSessionId ?? "" },
    {
      enabled: Boolean(activeLiveSessionId),
      refetchInterval: OPERATOR_POLL_INTERVALS_MS.active,
    }
  );
  const traceDetail = trpc.operator.traces.detail.useQuery(
    { traceId: selectedTraceId ?? "00000000-0000-4000-8000-000000000000" },
    {
      enabled: Boolean(selectedTraceId),
      refetchInterval: OPERATOR_POLL_INTERVALS_MS.index,
    }
  );
  const evidence = trpc.operator.evidence.inventory.useQuery(
    { traceId: selectedTraceId ?? "00000000-0000-4000-8000-000000000000" },
    {
      enabled:
        Boolean(selectedTraceId) && overview.data?.activation.open === true,
    }
  );
  const evidenceSummary = trpc.operator.evidence.summary.useQuery(
    { traceId: selectedTraceId ?? "00000000-0000-4000-8000-000000000000" },
    {
      enabled:
        Boolean(selectedTraceId) && overview.data?.activation.open === true,
    }
  );
  const liveScreenshot = trpc.operator.live.screenshot.useQuery(
    { sessionId: activeLiveSessionId ?? "" },
    {
      enabled:
        Boolean(activeLiveSessionId) && overview.data?.activation.open === true,
      refetchInterval: OPERATOR_POLL_INTERVALS_MS.screenshot,
    }
  );
  const utils = trpc.useUtils();

  const submitJob = trpc.operator.jobs.submit.useMutation({
    onSuccess: async result => {
      toast.success(
        result.duplicate ? "Existing idempotent job loaded" : "Job submitted"
      );
      if (!result.duplicate) setIdempotencyKey(newIdempotencyKey());
      await Promise.all([
        utils.operator.overview.invalidate(),
        utils.operator.jobs.list.invalidate(),
      ]);
    },
    onError: error => toast.error(error.message),
  });
  const cancelJob = trpc.operator.jobs.cancel.useMutation({
    onSuccess: async () => {
      toast.success("Cancellation requested");
      await utils.operator.overview.invalidate();
    },
    onError: error => toast.error(error.message),
  });
  const openLive = trpc.operator.live.open.useMutation({
    onSuccess: async () => {
      toast.success("Live Appium/WDA session requested");
      await utils.operator.overview.invalidate();
    },
    onError: error => toast.error(error.message),
  });
  const liveAction = trpc.operator.live.action.useMutation({
    onSuccess: async result => {
      toast.success(`${humanizeKind(result.kind)} completed`);
      await Promise.all([overview.refetch(), liveSession.refetch()]);
    },
    onError: error => toast.error(error.message),
  });
  const liveObserve = trpc.operator.live.observe.useMutation({
    onSuccess: async result => {
      toast.success(
        `${humanizeKind(result.receipt.kind)} observation completed`
      );
      await Promise.all([
        overview.refetch(),
        liveSession.refetch(),
        liveScreenshot.refetch(),
      ]);
    },
    onError: error => toast.error(error.message),
  });
  const prepareEvidence = trpc.operator.evidence.prepare.useMutation({
    onSuccess: async result => {
      toast.success(`${result.counts.verified} evidence files verified`);
      await Promise.all([evidence.refetch(), evidenceSummary.refetch()]);
    },
    onError: error => toast.error(error.message),
  });
  const setQuarantine = trpc.operator.quarantine.set.useMutation({
    onSuccess: async () => {
      setQuarantineReason("");
      toast.success("Quarantine enabled");
      await utils.operator.overview.invalidate();
    },
    onError: error => toast.error(error.message),
  });
  const clearQuarantine = trpc.operator.quarantine.clear.useMutation({
    onSuccess: async () => {
      setClearAcknowledgement("");
      toast.success("Quarantine cleared after device revalidation");
      await utils.operator.overview.invalidate();
    },
    onError: error => toast.error(error.message),
  });

  const data = overview.data;
  const activationOpen = data?.activation.open === true;
  const operational = activationOpen && data?.quarantine.active === false;
  const agentStale = Boolean(
    data?.agent.observedAt && Date.now() - data.agent.observedAt > 15_000
  );
  const readyDevices =
    data?.agent.cableDevices.filter(device => device.ready) ?? [];
  const selectedTrace = traceDetail.data;
  const displayedLive = liveSession.data ?? data?.activeLiveSession ?? null;
  const liveControllable =
    operational &&
    displayedLive?.state === "active" &&
    displayedLive.bidiConnected;
  const recentJobs = jobs.data ?? [];
  const traceRows = traces.data ?? [];
  const verifiedArtifacts = useMemo(
    () =>
      (evidence.data ?? []).filter(item => item.verified && item.downloadUrl),
    [evidence.data]
  );

  function executeSelectedLiveAction() {
    if (!displayedLive) return;
    if (liveActionKind !== "qa_command") {
      liveAction.mutate({ sessionId: displayedLive.id, kind: liveActionKind });
      return;
    }

    try {
      const parsed = JSON.parse(qaCommandJson) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("not-an-object");
      }
      liveAction.mutate({
        sessionId: displayedLive.id,
        kind: liveActionKind,
        command: parsed as Record<string, unknown>,
      });
    } catch {
      toast.error("QA command must be a valid JSON object");
    }
  }

  if (overview.error?.data?.code === "FORBIDDEN") {
    return <AccessDenied />;
  }

  if (overview.isLoading) {
    return <OperatorLoading />;
  }

  return (
    <div className="mx-auto flex w-full max-w-[1680px] flex-col gap-4 lg:gap-5">
      <section id="command-center" className="scroll-mt-6">
        <div className="mb-4 flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <p className="telemetry-eyebrow">
              FaceSwap Live / Operator Console
            </p>
            <h1 className="mt-2 text-2xl font-semibold tracking-[-0.03em] sm:text-3xl">
              Remote iOS automation command center
            </h1>
            <p className="mt-2 max-w-3xl text-sm leading-6 text-muted-foreground">
              Owner-gated control plane for cable-device XCUITest, Appium/WDA
              live sessions, trace correlation, verified evidence, and protected
              GitHub activation.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <LiveIndicator />
            <StatusChip
              state={data?.activation.state ?? "unavailable"}
              label={`Gate ${data?.activation.state ?? "unavailable"}`}
              pulse={activationOpen}
            />
            <Button
              variant="outline"
              size="sm"
              onClick={() => void overview.refetch()}
              disabled={overview.isFetching}
              className="font-mono text-xs"
            >
              <RefreshCw
                className={overview.isFetching ? "animate-spin" : ""}
              />
              Refresh
            </Button>
          </div>
        </div>

        {overview.error ? (
          <QueryFailure
            title="Operator overview unavailable"
            message={overview.error.message}
            onRetry={() => void overview.refetch()}
          />
        ) : (
          <Alert
            className={
              activationOpen
                ? "border-emerald-400/30 bg-emerald-400/5"
                : "border-destructive/45 bg-destructive/8"
            }
          >
            {activationOpen ? (
              <ShieldCheck className="h-4 w-4 text-emerald-300" />
            ) : (
              <LockKeyhole className="h-4 w-4 text-destructive" />
            )}
            <AlertTitle>
              {activationOpen
                ? "Activation gate open"
                : "Automation blocked fail-closed"}
            </AlertTitle>
            <AlertDescription className="mt-1 text-xs leading-5 text-muted-foreground">
              {data?.activation.summary ?? "Policy state unavailable."}
            </AlertDescription>
          </Alert>
        )}
      </section>

      <TelemetryPanel
        id="device-status"
        eyebrow="Node 01 / Hardware plane"
        title="Mac agent and physical device status"
        description="Live three-second polling from the server-side agent gateway. No agent credential is exposed to this browser."
        action={
          <StatusChip
            state={data?.agent.state ?? "offline"}
            pulse={data?.agent.state === "healthy"}
          />
        }
      >
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-6">
          <MetricCell
            label="Agent"
            value={agentStale ? "stale" : (data?.agent.state ?? "offline")}
            detail={
              data?.agent.version ?? data?.agent.errorCode ?? "No version"
            }
            state={
              data?.agent.state === "healthy" && !agentStale
                ? "success"
                : "danger"
            }
          />
          <MetricCell
            label="Queue depth"
            value={data?.agent.queueDepth ?? 0}
            detail="Serialized device jobs"
            state={(data?.agent.queueDepth ?? 0) > 0 ? "warning" : "neutral"}
          />
          <MetricCell
            label="Active job"
            value={shortId(data?.agent.activeJobId)}
            detail={data?.activeJob?.phase ?? "No device owner"}
            state={data?.agent.activeJobId ? "warning" : "neutral"}
          />
          <MetricCell
            label="Live session"
            value={shortId(data?.agent.activeLiveSessionId)}
            detail={displayedLive?.state ?? "No Appium lease"}
            state={data?.agent.activeLiveSessionId ? "violet" : "neutral"}
          />
          <MetricCell
            label="Appium"
            value={data?.agent.appiumState ?? "unknown"}
            detail="Managed Node 20 runtime"
            state={
              data?.agent.appiumState === "healthy" ? "success" : "warning"
            }
          />
          <MetricCell
            label="Observed"
            value={formatTimestamp(data?.agent.observedAt)}
            detail={
              data?.agent.latencyMs === null
                ? "Latency unavailable"
                : `${data?.agent.latencyMs} ms gateway latency`
            }
          />
        </div>
        {agentStale ? (
          <Alert className="mt-4 border-amber-300/30 bg-amber-300/5">
            <Clock3 className="h-4 w-4 text-amber-300" />
            <AlertTitle>Agent telemetry is stale</AlertTitle>
            <AlertDescription className="text-xs text-muted-foreground">
              The latest observation is more than 15 seconds old. Mutations
              remain blocked until fresh readiness data arrives.
            </AlertDescription>
          </Alert>
        ) : null}
        <div className="mt-4 grid gap-3 lg:grid-cols-2">
          {data?.agent.cableDevices.length ? (
            data.agent.cableDevices.map(device => (
              <article
                key={device.udid}
                className="rounded-xl border border-border/70 bg-background/30 p-4"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="flex min-w-0 items-start gap-3">
                    <div className="rounded-lg border border-primary/20 bg-primary/10 p-2 text-primary">
                      <Smartphone className="h-5 w-5" />
                    </div>
                    <div className="min-w-0">
                      <p className="font-medium">{device.name}</p>
                      <p className="mt-1 font-mono text-[11px] text-muted-foreground">
                        {device.model} · iOS {device.platformVersion}
                      </p>
                    </div>
                  </div>
                  <StatusChip state={device.ready ? "ready" : "blocked"} />
                </div>
                <p className="mt-4 break-all rounded-md bg-black/20 px-3 py-2 font-mono text-[10px] text-muted-foreground">
                  {device.udid}
                </p>
                <div className="mt-3 flex flex-wrap gap-2">
                  <StatusChip
                    state={device.transport === "usb" ? "connected" : "unknown"}
                    label={device.transport.toUpperCase()}
                  />
                  <StatusChip
                    state={device.paired ? "passed" : "failed"}
                    label="Paired"
                  />
                  <StatusChip
                    state={device.trusted ? "passed" : "failed"}
                    label="Trusted"
                  />
                  <StatusChip
                    state={device.developerMode ? "passed" : "failed"}
                    label="Developer mode"
                  />
                </div>
                {device.readinessReason ? (
                  <p className="mt-3 text-xs text-destructive">
                    {device.readinessReason}
                  </p>
                ) : null}
              </article>
            ))
          ) : (
            <div className="lg:col-span-2">
              <EmptyTelemetry
                title="No cable device telemetry"
                detail="Configure the private Mac-agent gateway and attach an authorized iPhone to populate exact pairing, trust, Developer Mode, and USB readiness state."
              />
            </div>
          )}
        </div>
      </TelemetryPanel>

      <div
        id="job-control"
        className="grid scroll-mt-6 gap-4 xl:grid-cols-[0.86fr_1.14fr]"
      >
        <TelemetryPanel
          eyebrow="Node 02 / Dispatch"
          title="Protected job submission"
          description="Closed scenario allowlist with exact device ownership and visible idempotency."
        >
          {!operational ? (
            <BlockedNotice
              message={
                activationOpen
                  ? "Job dispatch is blocked while quarantine is active."
                  : "Job dispatch is blocked until every activation policy check passes."
              }
            />
          ) : null}
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault();
              submitJob.mutate({
                scenario,
                deviceUdid,
                retryCount: Number(retryCount),
                idempotencyKey,
              });
            }}
          >
            <div className="grid gap-2">
              <Label htmlFor="scenario">Scenario</Label>
              <Select
                value={scenario}
                onValueChange={value => setScenario(value as OperatorScenario)}
              >
                <SelectTrigger id="scenario">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {OPERATOR_SCENARIOS.map(item => (
                    <SelectItem key={item} value={item}>
                      {item}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="grid gap-2">
              <Label htmlFor="device-udid">Physical device UDID</Label>
              <Input
                id="device-udid"
                value={deviceUdid}
                onChange={event => setDeviceUdid(event.target.value.trim())}
                placeholder="00008110-001234567890001E"
                className="font-mono text-xs"
                list="ready-device-list"
              />
              <datalist id="ready-device-list">
                {readyDevices.map(device => (
                  <option key={device.udid} value={device.udid}>
                    {device.name}
                  </option>
                ))}
              </datalist>
            </div>
            <div className="grid gap-2">
              <Label htmlFor="retry-count">Retry budget</Label>
              <Select value={retryCount} onValueChange={setRetryCount}>
                <SelectTrigger id="retry-count">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="0">0 · no retry</SelectItem>
                  <SelectItem value="1">1 · one bounded retry</SelectItem>
                  <SelectItem value="2">2 · maximum retry budget</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div className="rounded-lg border border-primary/25 bg-primary/5 p-3">
              <div className="flex items-center justify-between gap-3">
                <Label className="font-mono text-[10px] uppercase tracking-[0.14em] text-primary">
                  Idempotency key
                </Label>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="h-7 w-7"
                  onClick={() => {
                    void navigator.clipboard.writeText(idempotencyKey);
                    toast.success("Idempotency key copied");
                  }}
                  aria-label="Copy idempotency key"
                >
                  <Copy className="h-3.5 w-3.5" />
                </Button>
              </div>
              <p className="mt-2 break-all font-mono text-xs text-foreground">
                {idempotencyKey}
              </p>
              <p className="mt-2 text-[11px] leading-5 text-muted-foreground">
                Visible at all times. Reusing this key returns the original job
                instead of dispatching duplicate hardware work.
              </p>
            </div>
            <Button
              type="submit"
              disabled={!operational || !deviceUdid || submitJob.isPending}
            >
              {submitJob.isPending ? (
                <Loader2 className="animate-spin" />
              ) : (
                <Play />
              )}
              Dispatch protected job
            </Button>
          </form>
        </TelemetryPanel>

        <TelemetryPanel
          eyebrow="Node 03 / Execution"
          title="Live job monitor"
          description="Two-second polling for phase, elapsed time, terminal state, and bounded log tail."
          action={<LiveIndicator label="2s polling" />}
        >
          {jobs.error ? (
            <QueryFailure
              title="Job index unavailable"
              message={jobs.error.message}
              onRetry={() => void jobs.refetch()}
            />
          ) : data?.activeJob ? (
            <div className="space-y-4">
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                <MetricCell
                  label="Status"
                  value={<StatusChip state={data.activeJob.status} />}
                  detail={data.activeJob.phase}
                  state={
                    data.activeJob.status === "failed" ? "danger" : "warning"
                  }
                />
                <MetricCell
                  label="Scenario"
                  value={data.activeJob.scenario}
                  detail={`attempt ${data.activeJob.attempt} / retries ${data.activeJob.retryCount}`}
                />
                <MetricCell
                  label="Elapsed"
                  value={formatElapsed(
                    data.activeJob.startedAt,
                    data.activeJob.finishedAt
                  )}
                  detail={formatTimestamp(data.activeJob.startedAt)}
                />
                <MetricCell
                  label="Trace"
                  value={shortId(data.activeJob.traceId)}
                  detail="Root correlation identity"
                  state="violet"
                />
              </div>
              <div className="terminal-surface max-h-72 overflow-auto rounded-xl p-3 font-mono text-[11px] leading-5">
                {jobLog.error ? (
                  <p className="text-destructive">{jobLog.error.message}</p>
                ) : jobLog.data?.length ? (
                  jobLog.data.map(entry => (
                    <div
                      key={`${entry.sequence}-${entry.message}`}
                      className="grid grid-cols-[4.5rem_1fr] gap-3 border-b border-border/20 py-1.5 last:border-0"
                    >
                      <span
                        className={
                          entry.level === "error"
                            ? "text-destructive"
                            : entry.level === "warning"
                              ? "text-amber-300"
                              : "text-primary"
                        }
                      >
                        [{entry.level}]
                      </span>
                      <span className="break-words text-foreground/80">
                        {entry.message}
                      </span>
                    </div>
                  ))
                ) : (
                  <p className="text-muted-foreground">
                    Awaiting structured agent log data…
                  </p>
                )}
              </div>
              <div className="flex justify-end">
                <Button
                  variant="destructive"
                  size="sm"
                  disabled={
                    !activationOpen ||
                    cancelJob.isPending ||
                    ["succeeded", "failed", "cancelled", "timed_out"].includes(
                      data.activeJob.status
                    )
                  }
                  onClick={() => cancelJob.mutate({ id: data.activeJob!.id })}
                >
                  <CircleStop /> Request cancellation
                </Button>
              </div>
            </div>
          ) : (
            <EmptyTelemetry
              title="No active device job"
              detail="A protected dispatch will appear here as soon as the Mac agent claims exclusive device ownership."
            />
          )}
        </TelemetryPanel>
      </div>

      <TelemetryPanel
        id="live-session"
        eyebrow="Node 04 / Interactive channel"
        title="Appium / WebDriverAgent live session"
        description="Live session state, WDA liveness, mandatory BiDi connectivity, action/observation events, and the latest screenshot observation."
        action={
          <StatusChip
            state={displayedLive?.state ?? "idle"}
            pulse={displayedLive?.state === "active"}
          />
        }
      >
        {liveSession.error ? (
          <div className="mb-4">
            <QueryFailure
              title="Live session unavailable"
              message={liveSession.error.message}
              onRetry={() => void liveSession.refetch()}
            />
          </div>
        ) : null}
        <div className="grid gap-4 xl:grid-cols-[0.78fr_1.22fr]">
          <div className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <MetricCell
                label="Session"
                value={shortId(displayedLive?.id)}
                detail={
                  displayedLive
                    ? formatTimestamp(displayedLive.startedAt)
                    : "No active lease"
                }
                state="violet"
              />
              <MetricCell
                label="BiDi"
                value={
                  <StatusChip
                    state={
                      displayedLive?.bidiConnected ? "connected" : "offline"
                    }
                  />
                }
                detail="Custom event stream"
                state={displayedLive?.bidiConnected ? "success" : "danger"}
              />
              <MetricCell
                label="WebDriverAgent"
                value={displayedLive?.wdaState ?? "unknown"}
                detail="Independent liveness probe"
                state={
                  displayedLive?.wdaState === "healthy" ? "success" : "warning"
                }
              />
              <MetricCell
                label="Lease expiry"
                value={formatTimestamp(displayedLive?.expiresAt)}
                detail={
                  displayedLive
                    ? `last heartbeat ${formatTimestamp(displayedLive.lastHeartbeatAt)}`
                    : "—"
                }
              />
            </div>
            <div className="grid gap-2">
              <Label htmlFor="live-device">Device UDID</Label>
              <Input
                id="live-device"
                value={deviceUdid}
                onChange={event => setDeviceUdid(event.target.value.trim())}
                placeholder="00008110-001234567890001E"
                className="font-mono text-xs"
              />
            </div>
            <Button
              className="w-full"
              variant="secondary"
              disabled={
                !operational ||
                !deviceUdid ||
                Boolean(displayedLive) ||
                openLive.isPending
              }
              onClick={() =>
                openLive.mutate({
                  deviceUdid,
                  idempotencyKey: crypto.randomUUID(),
                })
              }
            >
              {openLive.isPending ? (
                <Loader2 className="animate-spin" />
              ) : (
                <RadioTower />
              )}
              Start guarded live session
            </Button>
            <div className="rounded-xl border border-border/70 bg-background/25 p-3">
              <div className="flex items-center justify-between gap-3">
                <p className="metric-label">Allowlisted live action</p>
                <StatusChip state={liveControllable ? "ready" : "blocked"} />
              </div>
              <div className="mt-3 grid gap-3">
                <Select
                  value={liveActionKind}
                  onValueChange={value =>
                    setLiveActionKind(value as LiveActionKind)
                  }
                >
                  <SelectTrigger aria-label="Live action kind">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {LIVE_ACTION_KINDS.map(item => (
                      <SelectItem key={item} value={item}>
                        {humanizeKind(item)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {liveActionKind === "qa_command" ? (
                  <div className="grid gap-2">
                    <Label htmlFor="qa-command-json">
                      Registered QA command JSON
                    </Label>
                    <Textarea
                      id="qa-command-json"
                      value={qaCommandJson}
                      onChange={event => setQaCommandJson(event.target.value)}
                      maxLength={32 * 1024}
                      spellCheck={false}
                      className="min-h-28 font-mono text-[11px]"
                    />
                  </div>
                ) : null}
                <Button
                  size="sm"
                  disabled={!liveControllable || liveAction.isPending}
                  onClick={executeSelectedLiveAction}
                >
                  {liveAction.isPending ? (
                    <Loader2 className="animate-spin" />
                  ) : (
                    <TerminalSquare />
                  )}
                  Execute guarded action
                </Button>
                {liveAction.data ? (
                  <p className="break-all font-mono text-[10px] text-muted-foreground">
                    {liveAction.data.success ? "success" : "failed"} · operation{" "}
                    {liveAction.data.operationTraceId}
                    {liveAction.data.elapsedMs === null
                      ? ""
                      : ` · ${liveAction.data.elapsedMs} ms`}
                  </p>
                ) : null}
              </div>
            </div>
            <div className="rounded-xl border border-border/70 bg-background/25 p-3">
              <p className="metric-label">Bounded observation</p>
              <div className="mt-3 grid gap-3 sm:grid-cols-[1fr_auto]">
                <Select
                  value={liveObservationKind}
                  onValueChange={value =>
                    setLiveObservationKind(value as LiveObservationKind)
                  }
                >
                  <SelectTrigger aria-label="Live observation kind">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {LIVE_OBSERVATION_KINDS.map(item => (
                      <SelectItem key={item} value={item}>
                        {humanizeKind(item)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={!liveControllable || liveObserve.isPending}
                  onClick={() =>
                    displayedLive &&
                    liveObserve.mutate({
                      sessionId: displayedLive.id,
                      kind: liveObservationKind,
                    })
                  }
                >
                  {liveObserve.isPending ? (
                    <Loader2 className="animate-spin" />
                  ) : (
                    <Camera />
                  )}
                  Capture
                </Button>
              </div>
              {liveObserve.data ? (
                <p className="mt-3 break-all font-mono text-[10px] text-muted-foreground">
                  {liveObserve.data.receipt.success ? "success" : "failed"} ·
                  operation {liveObserve.data.receipt.operationTraceId}
                </p>
              ) : null}
            </div>
          </div>
          <div className="grid gap-4 md:grid-cols-2">
            <div className="scan-screen flex min-h-64 flex-col items-center justify-center rounded-xl border border-primary/20 p-5 text-center">
              {liveScreenshot.isLoading ? (
                <>
                  <Loader2 className="h-9 w-9 animate-spin text-primary" />
                  <p className="mt-4 font-mono text-xs uppercase tracking-[0.12em]">
                    Loading verified observation
                  </p>
                </>
              ) : liveScreenshot.error ? (
                <>
                  <AlertTriangle className="h-10 w-10 text-destructive" />
                  <p className="mt-4 font-mono text-xs uppercase tracking-[0.12em] text-destructive">
                    Screenshot unavailable
                  </p>
                  <p className="mt-2 max-w-xs text-xs leading-5 text-muted-foreground">
                    {liveScreenshot.error.message}
                  </p>
                  <Button
                    className="mt-4"
                    size="sm"
                    variant="outline"
                    onClick={() => void liveScreenshot.refetch()}
                  >
                    <RefreshCw /> Retry
                  </Button>
                </>
              ) : liveScreenshot.data ? (
                <>
                  <a
                    href={liveScreenshot.data.downloadUrl}
                    target="_blank"
                    rel="noreferrer"
                    className="group block w-full"
                  >
                    <img
                      src={liveScreenshot.data.downloadUrl}
                      alt="Latest SHA-256 verified iPhone observation"
                      className="mx-auto max-h-80 w-auto rounded-lg border border-primary/25 object-contain shadow-[0_0_28px_rgba(34,211,238,0.12)] transition-transform group-hover:scale-[1.01]"
                    />
                  </a>
                  <div className="mt-3 flex flex-wrap justify-center gap-2">
                    <StatusChip state="verified" />
                    <StatusChip state="pending" label="Operator-sensitive" />
                  </div>
                  <p className="mt-2 text-[10px] text-muted-foreground">
                    {formatBytes(liveScreenshot.data.sizeBytes)} ·{" "}
                    {formatTimestamp(liveScreenshot.data.capturedAt)}
                  </p>
                  <p className="mt-2 break-all font-mono text-[9px] text-muted-foreground">
                    SHA-256 {liveScreenshot.data.sha256}
                  </p>
                </>
              ) : (
                <>
                  <Fingerprint className="h-10 w-10 text-primary/70" />
                  <p className="mt-4 font-mono text-xs uppercase tracking-[0.12em]">
                    Latest verified observation
                  </p>
                  <p className="mt-2 max-w-xs text-xs leading-5 text-muted-foreground">
                    Capture a screenshot after an active BiDi session starts.
                    The server verifies the exact bytes against the Mac-agent
                    SHA-256 before a storage URL reaches this browser.
                  </p>
                </>
              )}
            </div>
            <div className="terminal-surface max-h-72 overflow-auto rounded-xl p-3 font-mono text-[11px] leading-5">
              {displayedLive?.stream.length ? (
                displayedLive.stream.map(event => (
                  <div
                    key={event.sequence}
                    className="border-b border-border/20 py-2 last:border-0"
                  >
                    <div className="flex items-center justify-between gap-2">
                      <span className="text-primary">{event.kind}</span>
                      <StatusChip state={event.outcome} />
                    </div>
                    <p className="mt-1 break-words text-foreground/80">
                      {event.summary}
                    </p>
                    <p className="mt-1 text-[9px] text-muted-foreground">
                      {formatTimestamp(event.timestamp)} ·{" "}
                      {shortId(event.operationTraceId)}
                    </p>
                  </div>
                ))
              ) : (
                <p className="text-muted-foreground">
                  No active action or observation events.
                </p>
              )}
            </div>
          </div>
        </div>
      </TelemetryPanel>

      <div
        id="trace-explorer"
        className="grid scroll-mt-6 gap-4 xl:grid-cols-[0.72fr_1.28fr]"
      >
        <TelemetryPanel
          eyebrow="Node 05 / Correlation index"
          title="Root traces"
          description="W3C trace identities spanning dashboard, agent, Xcode, Appium, WDA, BiDi, and iOS."
        >
          <div className="space-y-2">
            {traces.error ? (
              <QueryFailure
                title="Trace index unavailable"
                message={traces.error.message}
                onRetry={() => void traces.refetch()}
              />
            ) : traceRows.length ? (
              traceRows.map(trace => (
                <button
                  key={trace.traceId}
                  onClick={() => setSelectedTraceId(trace.traceId)}
                  className={`w-full rounded-lg border p-3 text-left transition-colors ${selectedTraceId === trace.traceId ? "border-accent/60 bg-accent/10" : "border-border/60 bg-background/20 hover:border-primary/40"}`}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <p className="font-mono text-xs text-foreground">
                        {shortId(trace.traceId, 12)}
                      </p>
                      <p className="mt-1 text-[11px] text-muted-foreground">
                        {trace.ownerType} · {shortId(trace.ownerId)}
                      </p>
                    </div>
                    <StatusChip state={trace.status} />
                  </div>
                  <p className="mt-2 truncate font-mono text-[9px] text-muted-foreground">
                    {trace.traceparent}
                  </p>
                </button>
              ))
            ) : (
              <EmptyTelemetry
                title="No correlated traces"
                detail="Completed jobs and live sessions will populate this root-trace index."
              />
            )}
          </div>
        </TelemetryPanel>
        <TelemetryPanel
          eyebrow="Node 06 / Timeline"
          title="Trace timeline and invariants"
          description="Ordered events, typed recovery episodes, and deterministic qualification results."
          action={
            selectedTrace ? (
              <StatusChip
                state={
                  selectedTrace.invariants.every(item => item.passed)
                    ? "passed"
                    : "failed"
                }
              />
            ) : null
          }
        >
          {traceDetail.error ? (
            <QueryFailure
              title="Trace detail unavailable"
              message={traceDetail.error.message}
              onRetry={() => void traceDetail.refetch()}
            />
          ) : selectedTrace ? (
            <div className="space-y-4">
              <div className="rounded-lg border border-accent/25 bg-accent/5 p-3">
                <p className="metric-label">W3C traceparent</p>
                <p className="mt-2 break-all font-mono text-[11px] text-accent-foreground">
                  {selectedTrace.traceparent}
                </p>
              </div>
              <div className="grid gap-3 md:grid-cols-2">
                <div className="space-y-2">
                  <p className="metric-label">Correlated events</p>
                  {selectedTrace.timeline.length ? (
                    selectedTrace.timeline.slice(0, 20).map(event => (
                      <div
                        key={event.sequence}
                        className="rounded-lg border border-border/50 bg-background/25 p-3"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span className="font-mono text-[10px] uppercase text-primary">
                            {event.source} / {event.eventType}
                          </span>
                          <StatusChip state={event.outcome} />
                        </div>
                        <p className="mt-2 text-xs text-foreground/80">
                          {event.summary}
                        </p>
                        <p className="mt-1 font-mono text-[9px] text-muted-foreground">
                          {formatTimestamp(event.timestamp)} · span{" "}
                          {shortId(event.spanId)}
                        </p>
                      </div>
                    ))
                  ) : (
                    <p className="text-xs text-muted-foreground">
                      No events recorded.
                    </p>
                  )}
                </div>
                <div className="space-y-4">
                  <div>
                    <p className="metric-label">Analytics invariants</p>
                    <div className="mt-2 space-y-2">
                      {selectedTrace.invariants.length ? (
                        selectedTrace.invariants.map(item => (
                          <div
                            key={item.key}
                            className="flex items-start justify-between gap-3 rounded-lg border border-border/50 bg-background/25 p-3"
                          >
                            <div>
                              <p className="text-xs font-medium">
                                {item.label}
                              </p>
                              <p className="mt-1 font-mono text-[9px] text-muted-foreground">
                                actual {item.actual} · expected {item.expected}
                              </p>
                            </div>
                            {item.passed ? (
                              <Check className="h-4 w-4 text-emerald-300" />
                            ) : (
                              <X className="h-4 w-4 text-destructive" />
                            )}
                          </div>
                        ))
                      ) : (
                        <p className="text-xs text-muted-foreground">
                          No invariant results.
                        </p>
                      )}
                    </div>
                  </div>
                  <div>
                    <p className="metric-label">Recovery episodes</p>
                    <div className="mt-2 space-y-2">
                      {selectedTrace.recoveries.length ? (
                        selectedTrace.recoveries.map(item => (
                          <div
                            key={item.id}
                            className="rounded-lg border border-amber-300/20 bg-amber-300/5 p-3"
                          >
                            <div className="flex items-center justify-between gap-2">
                              <p className="text-xs font-medium">
                                {item.cause}
                              </p>
                              <StatusChip state={item.outcome} />
                            </div>
                            <p className="mt-2 text-xs text-muted-foreground">
                              {item.summary}
                            </p>
                          </div>
                        ))
                      ) : (
                        <p className="text-xs text-muted-foreground">
                          No recovery episode for this trace.
                        </p>
                      )}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          ) : (
            <EmptyTelemetry
              title="Select a root trace"
              detail="Choose a trace from the index to reconstruct its cross-stack timeline, recovery ledger, and analytics invariants."
            />
          )}
        </TelemetryPanel>
      </div>

      <TelemetryPanel
        id="evidence-browser"
        eyebrow="Node 07 / Verified evidence"
        title="Evidence archive and artifact inventory"
        description="Download links surface only after the dashboard server re-hashes exact archive and file bytes against the Mac-agent manifest."
        action={
          selectedTraceId ? (
            <Button
              size="sm"
              variant="outline"
              disabled={!activationOpen || prepareEvidence.isPending}
              onClick={() =>
                prepareEvidence.mutate({ traceId: selectedTraceId })
              }
            >
              {prepareEvidence.isPending ? (
                <Loader2 className="animate-spin" />
              ) : (
                <HardDriveDownload />
              )}{" "}
              Verify archive
            </Button>
          ) : null
        }
      >
        {selectedTraceId ? (
          <div className="space-y-4">
            {!activationOpen ? (
              <BlockedNotice message="Evidence retrieval is blocked until the activation gate opens." />
            ) : null}
            {evidence.error ? (
              <QueryFailure
                title="Evidence inventory unavailable"
                message={evidence.error.message}
                onRetry={() => void evidence.refetch()}
              />
            ) : null}
            {evidenceSummary.isLoading ? (
              <div className="rounded-xl border border-border/70 bg-background/25 p-4 text-xs text-muted-foreground">
                Loading persisted evidence summary…
              </div>
            ) : evidenceSummary.error ? (
              <Alert className="border-destructive/35 bg-destructive/5">
                <AlertTriangle className="h-4 w-4 text-destructive" />
                <AlertTitle>Evidence summary unavailable</AlertTitle>
                <AlertDescription className="text-xs text-muted-foreground">
                  {evidenceSummary.error.message}
                </AlertDescription>
              </Alert>
            ) : evidenceSummary.data ? (
              <div className="rounded-xl border border-accent/30 bg-accent/5 p-4">
                <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div>
                    <p className="metric-label">Sanitized archive summary</p>
                    <p className="mt-2 text-sm font-medium">
                      {evidenceSummary.data.status}
                    </p>
                    <p className="mt-1 text-xs text-muted-foreground">
                      Verified{" "}
                      {formatTimestamp(evidenceSummary.data.verifiedAt)}
                    </p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <StatusChip
                      state={
                        evidenceSummary.data.allVerified
                          ? "verified"
                          : "rejected"
                      }
                      label={`${evidenceSummary.data.verifiedCount}/${evidenceSummary.data.totalCount} verified`}
                    />
                    <StatusChip
                      state={
                        evidenceSummary.data.allSanitized ? "passed" : "blocked"
                      }
                      label={`${evidenceSummary.data.sanitizedCount}/${evidenceSummary.data.totalCount} sanitized`}
                    />
                  </div>
                </div>
                <div className="mt-4 grid gap-3 sm:grid-cols-3">
                  <MetricCell
                    label="Archive size"
                    value={formatBytes(evidenceSummary.data.archiveSizeBytes)}
                    detail="Bounded tar.gz"
                  />
                  <MetricCell
                    label="Rejected"
                    value={evidenceSummary.data.rejectedCount}
                    detail="No download URL"
                    state={
                      evidenceSummary.data.rejectedCount ? "danger" : "success"
                    }
                  />
                  <MetricCell
                    label="Manifest"
                    value={shortId(evidenceSummary.data.manifestSha256, 12)}
                    detail="SHA-256 verified"
                    state="violet"
                  />
                </div>
                <p className="mt-3 break-all font-mono text-[9px] text-muted-foreground">
                  Archive SHA-256 {evidenceSummary.data.archiveSha256}
                </p>
                {evidenceSummary.data.reasons.length ? (
                  <ul className="mt-3 space-y-1 text-xs text-muted-foreground">
                    {evidenceSummary.data.reasons.map(reason => (
                      <li key={reason}>• {reason}</li>
                    ))}
                  </ul>
                ) : (
                  <p className="mt-3 text-xs text-emerald-300">
                    No archive-level rejection reason reported.
                  </p>
                )}
              </div>
            ) : (
              <Alert className="border-amber-300/25 bg-amber-300/5">
                <AlertTriangle className="h-4 w-4 text-amber-300" />
                <AlertTitle>No verified archive summary yet</AlertTitle>
                <AlertDescription className="text-xs text-muted-foreground">
                  Run “Verify archive” to persist archive status, sanitized
                  counts, reasons, manifest hash, and exact archive SHA-256.
                </AlertDescription>
              </Alert>
            )}
            <Alert className="border-primary/25 bg-primary/5">
              <FileCheck2 className="h-4 w-4 text-primary" />
              <AlertTitle>Server-enforced SHA-256</AlertTitle>
              <AlertDescription className="text-xs text-muted-foreground">
                Only {verifiedArtifacts.length} artifact
                {verifiedArtifacts.length === 1 ? " is" : "s are"} eligible for
                download. Mismatched, missing, oversized, unsafe-path, or
                unverified files remain linkless.
              </AlertDescription>
            </Alert>
            <div className="overflow-x-auto rounded-xl border border-border/70">
              <table className="w-full min-w-[760px] text-left text-xs">
                <thead className="bg-muted/35 font-mono text-[10px] uppercase tracking-[0.12em] text-muted-foreground">
                  <tr>
                    <th className="px-4 py-3">Artifact</th>
                    <th className="px-4 py-3">Kind</th>
                    <th className="px-4 py-3">Size</th>
                    <th className="px-4 py-3">SHA-256</th>
                    <th className="px-4 py-3">State</th>
                    <th className="px-4 py-3 text-right">Download</th>
                  </tr>
                </thead>
                <tbody>
                  {evidence.data?.length ? (
                    evidence.data.map(item => (
                      <tr key={item.id} className="border-t border-border/50">
                        <td className="max-w-64 break-words px-4 py-3 text-foreground">
                          {item.name}
                        </td>
                        <td className="px-4 py-3 text-muted-foreground">
                          {item.kind}
                        </td>
                        <td className="px-4 py-3 font-mono">
                          {formatBytes(item.sizeBytes)}
                        </td>
                        <td
                          className="max-w-52 truncate px-4 py-3 font-mono text-[10px] text-muted-foreground"
                          title={item.sha256}
                        >
                          {item.sha256}
                        </td>
                        <td className="px-4 py-3">
                          <StatusChip
                            state={item.verified ? "verified" : "rejected"}
                          />
                        </td>
                        <td className="px-4 py-3 text-right">
                          {item.verified && item.downloadUrl ? (
                            <Button asChild variant="ghost" size="sm">
                              <a href={item.downloadUrl} download>
                                <Download /> File
                              </a>
                            </Button>
                          ) : (
                            <span className="font-mono text-[10px] text-destructive">
                              blocked
                            </span>
                          )}
                        </td>
                      </tr>
                    ))
                  ) : (
                    <tr>
                      <td
                        colSpan={6}
                        className="p-6 text-center text-muted-foreground"
                      >
                        No dashboard-verified evidence inventory yet.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        ) : (
          <EmptyTelemetry
            title="Select a trace to inspect evidence"
            detail="Evidence verification is trace-scoped so every artifact keeps its root correlation identity."
          />
        )}
      </TelemetryPanel>

      <div className="grid gap-4 xl:grid-cols-2">
        <TelemetryPanel
          id="quarantine"
          eyebrow="Node 08 / Containment"
          title="Quarantine management"
          description="Mutations remain owner-gated and policy-gated. Clearing requires the exact acknowledgement plus agent-side idle and readiness checks."
          action={
            <StatusChip
              state={data?.quarantine.active ? "quarantined" : "ready"}
              label={
                data?.quarantine.active ? "Quarantined" : "Not quarantined"
              }
            />
          }
        >
          <div className="space-y-5">
            {!activationOpen ? (
              <BlockedNotice message="Quarantine changes are blocked until the activation policy can be verified." />
            ) : null}
            <div className="grid gap-3 sm:grid-cols-2">
              <MetricCell
                label="State"
                value={data?.quarantine.active ? "ACTIVE" : "CLEAR"}
                detail={data?.quarantine.reason ?? "No active marker"}
                state={data?.quarantine.active ? "danger" : "success"}
              />
              <MetricCell
                label="Mode"
                value={data?.quarantine.mode ?? "—"}
                detail={formatTimestamp(data?.quarantine.setAt)}
              />
            </div>
            <Separator />
            <form
              className="grid gap-3"
              onSubmit={event => {
                event.preventDefault();
                setQuarantine.mutate({
                  mode: quarantineMode,
                  reason: quarantineReason,
                });
              }}
            >
              <div className="grid gap-2">
                <Label>Quarantine mode</Label>
                <Select
                  value={quarantineMode}
                  onValueChange={value =>
                    setQuarantineMode(value as QuarantineMode)
                  }
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {QUARANTINE_MODES.map(item => (
                      <SelectItem key={item} value={item}>
                        {item}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="grid gap-2">
                <Label htmlFor="quarantine-reason">Reason</Label>
                <Textarea
                  id="quarantine-reason"
                  value={quarantineReason}
                  onChange={event => setQuarantineReason(event.target.value)}
                  maxLength={240}
                  placeholder="Describe the bounded maintenance or containment reason…"
                />
              </div>
              <Button
                variant="destructive"
                type="submit"
                disabled={
                  !activationOpen ||
                  quarantineReason.trim().length < 8 ||
                  setQuarantine.isPending
                }
              >
                <Ban /> Set quarantine
              </Button>
            </form>
            <Separator />
            <div className="grid gap-3">
              <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-3">
                <p className="metric-label text-destructive">
                  Exact acknowledgement required
                </p>
                <p className="mt-2 break-words font-mono text-[10px] text-foreground">
                  {QUARANTINE_CLEAR_ACKNOWLEDGEMENT}
                </p>
              </div>
              <Input
                aria-label="Exact quarantine clear acknowledgement"
                value={clearAcknowledgement}
                onChange={event => setClearAcknowledgement(event.target.value)}
                placeholder="Type the exact acknowledgement"
                className="font-mono text-xs"
              />
              <Button
                variant="outline"
                disabled={
                  !activationOpen ||
                  !data?.quarantine.active ||
                  clearAcknowledgement !== QUARANTINE_CLEAR_ACKNOWLEDGEMENT ||
                  clearQuarantine.isPending
                }
                onClick={() =>
                  clearQuarantine.mutate({
                    acknowledgement: QUARANTINE_CLEAR_ACKNOWLEDGEMENT,
                  })
                }
              >
                <ShieldCheck /> Clear and revalidate
              </Button>
            </div>
          </div>
        </TelemetryPanel>

        <TelemetryPanel
          id="policy-status"
          eyebrow="Node 09 / External authorization"
          title="GitHub policy status"
          description="The repository is never assumed safe. Missing, stale, unknown, or permission-gated checks are failures."
          action={
            <StatusChip state={data?.activation.state ?? "unavailable"} />
          }
        >
          <div className="space-y-4">
            <div className="rounded-lg border border-border/70 bg-background/25 p-3">
              <div className="flex items-center justify-between gap-3">
                <div>
                  <p className="metric-label">Repository</p>
                  <p className="mt-2 break-all font-mono text-xs">
                    {data?.activation.repository ?? "unavailable"}
                  </p>
                </div>
                <StatusChip
                  state={
                    data?.activation.repositoryPrivate ? "passed" : "failed"
                  }
                  label={
                    data?.activation.repositoryPrivate
                      ? "Private"
                      : "Not private"
                  }
                />
              </div>
            </div>
            <div className="space-y-2">
              {data?.activation.checks.map(check => (
                <div
                  key={check.key}
                  className="flex items-start gap-3 rounded-lg border border-border/55 bg-background/25 p-3"
                >
                  <div
                    className={`mt-0.5 rounded-full p-1 ${check.passed ? "bg-emerald-300/10 text-emerald-300" : "bg-destructive/10 text-destructive"}`}
                  >
                    {check.passed ? (
                      <Check className="h-3.5 w-3.5" />
                    ) : (
                      <X className="h-3.5 w-3.5" />
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="text-xs font-medium">{check.label}</p>
                    <p className="mt-1 text-[11px] leading-5 text-muted-foreground">
                      {check.detail}
                    </p>
                  </div>
                  <StatusChip state={check.passed ? "passed" : "failed"} />
                </div>
              ))}
            </div>
            <div className="rounded-lg border border-amber-300/25 bg-amber-300/5 p-3">
              <div className="flex gap-3">
                <ExternalLink className="mt-0.5 h-4 w-4 shrink-0 text-amber-300" />
                <div>
                  <p className="text-xs font-medium text-amber-100">
                    External activation checklist
                  </p>
                  <ul className="mt-2 space-y-1.5 text-[11px] leading-5 text-muted-foreground">
                    <li>1. Make the GitHub repository private.</li>
                    <li>
                      2. Configure the protected physical-device environment and
                      required reviewer.
                    </li>
                    <li>
                      3. Restrict workflow permissions and set the activation
                      variable.
                    </li>
                    <li>
                      4. Register the dedicated labeled Mac runner and bind the
                      exact iPhone UDID.
                    </li>
                    <li>
                      5. Configure the dashboard’s private server-only Mac-agent
                      gateway.
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </div>
        </TelemetryPanel>
      </div>

      <footer className="flex flex-col gap-2 border-t border-border/60 px-1 py-5 text-[10px] text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
        <p className="font-mono uppercase tracking-[0.12em]">
          Owner-only · fail-closed · server-verified evidence
        </p>
        <p>Last dashboard refresh {formatTimestamp(data?.refreshedAt)}</p>
      </footer>
    </div>
  );
}

function AccessDenied() {
  return (
    <div className="flex min-h-[70vh] items-center justify-center">
      <div className="telemetry-panel max-w-xl p-8 text-center">
        <ShieldAlert className="mx-auto h-10 w-10 text-destructive" />
        <p className="telemetry-eyebrow mt-5">Authorization denied</p>
        <h1 className="mt-2 text-xl font-semibold">Owner role required</h1>
        <p className="mt-3 text-sm leading-6 text-muted-foreground">
          Your Manus account is authenticated, but it is not the configured
          owner identity. No telemetry or operator procedure was exposed.
        </p>
      </div>
    </div>
  );
}

function OperatorLoading() {
  return (
    <div className="flex min-h-[70vh] items-center justify-center">
      <div className="text-center">
        <Loader2 className="mx-auto h-7 w-7 animate-spin text-primary" />
        <p className="telemetry-eyebrow mt-4">
          Establishing secure telemetry channel
        </p>
      </div>
    </div>
  );
}

function QueryFailure({
  title,
  message,
  onRetry,
}: {
  title: string;
  message: string;
  onRetry: () => void;
}) {
  return (
    <Alert className="border-destructive/35 bg-destructive/5">
      <AlertTriangle className="h-4 w-4 text-destructive" />
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription className="mt-1 text-xs text-muted-foreground">
        {message}
      </AlertDescription>
      <Button
        className="mt-3"
        type="button"
        size="sm"
        variant="outline"
        onClick={onRetry}
      >
        <RefreshCw /> Retry
      </Button>
    </Alert>
  );
}

function BlockedNotice({ message }: { message: string }) {
  return (
    <Alert className="mb-4 border-amber-300/25 bg-amber-300/5">
      <LockKeyhole className="h-4 w-4 text-amber-300" />
      <AlertTitle>Protected operation blocked</AlertTitle>
      <AlertDescription className="text-xs text-muted-foreground">
        {message}
      </AlertDescription>
    </Alert>
  );
}

function shortId(value: string | null | undefined, length = 8) {
  if (!value) return "—";
  return value.length <= length ? value : `${value.slice(0, length)}…`;
}

function humanizeKind(value: string) {
  return value.replaceAll("_", " ");
}
