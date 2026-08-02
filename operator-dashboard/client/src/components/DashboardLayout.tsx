import { useAuth } from "@/_core/hooks/useAuth";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
  useSidebar,
} from "@/components/ui/sidebar";
import { startLogin } from "@/const";
import { useIsMobile } from "@/hooks/useMobile";
import {
  Activity,
  Archive,
  GitBranch,
  LayoutDashboard,
  ListChecks,
  LockKeyhole,
  LogOut,
  PanelLeft,
  RadioTower,
  ShieldAlert,
  Smartphone,
} from "lucide-react";
import { type CSSProperties, useEffect, useRef, useState } from "react";
import { DashboardLayoutSkeleton } from "./DashboardLayoutSkeleton";

const menuItems = [
  { icon: LayoutDashboard, label: "Command center", section: "command-center" },
  { icon: Smartphone, label: "Device & agent", section: "device-status" },
  { icon: ListChecks, label: "Job control", section: "job-control" },
  { icon: RadioTower, label: "Live session", section: "live-session" },
  { icon: GitBranch, label: "Trace explorer", section: "trace-explorer" },
  { icon: Archive, label: "Evidence", section: "evidence-browser" },
  { icon: ShieldAlert, label: "Quarantine", section: "quarantine" },
  { icon: LockKeyhole, label: "GitHub policy", section: "policy-status" },
];

const SIDEBAR_WIDTH_KEY = "faceswap-operator-sidebar-width";
const DEFAULT_WIDTH = 272;
const MIN_WIDTH = 224;
const MAX_WIDTH = 380;

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const [sidebarWidth, setSidebarWidth] = useState(() => {
    const saved = localStorage.getItem(SIDEBAR_WIDTH_KEY);
    return saved ? Number.parseInt(saved, 10) : DEFAULT_WIDTH;
  });
  const { loading, user } = useAuth();

  useEffect(() => {
    localStorage.setItem(SIDEBAR_WIDTH_KEY, sidebarWidth.toString());
  }, [sidebarWidth]);

  if (loading) return <DashboardLayoutSkeleton />;

  if (!user) {
    return (
      <div className="operator-grid flex min-h-screen items-center justify-center p-5">
        <div className="telemetry-panel flex w-full max-w-lg flex-col items-center gap-8 p-8 sm:p-12">
          <div className="flex h-14 w-14 items-center justify-center rounded-2xl border border-primary/40 bg-primary/10 shadow-[0_0_40px_rgba(34,211,238,0.18)]">
            <Activity className="h-7 w-7 text-primary" />
          </div>
          <div className="text-center">
            <p className="telemetry-eyebrow">FaceSwap Live / Remote Ops</p>
            <h1 className="mt-2 text-2xl font-semibold tracking-tight">
              Authenticate operator identity
            </h1>
            <p className="mt-4 text-sm leading-6 text-muted-foreground">
              This console is restricted to the configured owner. Manus OAuth is
              required before any telemetry or control plane is exposed.
            </p>
          </div>
          <div className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.14em] text-destructive">
            <LockKeyhole className="h-3.5 w-3.5" />
            fail-closed authorization boundary
          </div>
          <Button
            onClick={() => startLogin()}
            size="lg"
            className="w-full shadow-[0_0_24px_rgba(34,211,238,0.18)]"
          >
            Continue with Manus OAuth
          </Button>
        </div>
      </div>
    );
  }

  return (
    <SidebarProvider
      style={{ "--sidebar-width": `${sidebarWidth}px` } as CSSProperties}
    >
      <DashboardLayoutContent setSidebarWidth={setSidebarWidth}>
        {children}
      </DashboardLayoutContent>
    </SidebarProvider>
  );
}

function DashboardLayoutContent({
  children,
  setSidebarWidth,
}: {
  children: React.ReactNode;
  setSidebarWidth: (width: number) => void;
}) {
  const { user, logout } = useAuth();
  const { state, toggleSidebar } = useSidebar();
  const isCollapsed = state === "collapsed";
  const [isResizing, setIsResizing] = useState(false);
  const [activeSection, setActiveSection] = useState("command-center");
  const sidebarRef = useRef<HTMLDivElement>(null);
  const isMobile = useIsMobile();
  const activeMenuItem = menuItems.find(item => item.section === activeSection);

  useEffect(() => {
    if (isCollapsed) setIsResizing(false);
  }, [isCollapsed]);

  useEffect(() => {
    const handleMouseMove = (event: MouseEvent) => {
      if (!isResizing) return;
      const left = sidebarRef.current?.getBoundingClientRect().left ?? 0;
      const width = event.clientX - left;
      if (width >= MIN_WIDTH && width <= MAX_WIDTH) setSidebarWidth(width);
    };
    const handleMouseUp = () => setIsResizing(false);
    if (isResizing) {
      document.addEventListener("mousemove", handleMouseMove);
      document.addEventListener("mouseup", handleMouseUp);
      document.body.style.cursor = "col-resize";
      document.body.style.userSelect = "none";
    }
    return () => {
      document.removeEventListener("mousemove", handleMouseMove);
      document.removeEventListener("mouseup", handleMouseUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };
  }, [isResizing, setSidebarWidth]);

  useEffect(() => {
    const observer = new IntersectionObserver(
      entries => {
        const visible = entries
          .filter(entry => entry.isIntersecting)
          .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
        if (visible?.target.id) setActiveSection(visible.target.id);
      },
      { rootMargin: "-20% 0px -65% 0px", threshold: [0.05, 0.25, 0.5] }
    );
    menuItems.forEach(item => {
      const element = document.getElementById(item.section);
      if (element) observer.observe(element);
    });
    return () => observer.disconnect();
  }, []);

  const navigateTo = (section: string) => {
    setActiveSection(section);
    document.getElementById(section)?.scrollIntoView({
      behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches
        ? "auto"
        : "smooth",
      block: "start",
    });
  };

  return (
    <>
      <div className="relative" ref={sidebarRef}>
        <Sidebar
          collapsible="icon"
          className="border-r border-sidebar-border bg-sidebar/95 backdrop-blur-xl"
          disableTransition={isResizing}
        >
          <SidebarHeader className="h-20 justify-center border-b border-sidebar-border/70">
            <div className="flex w-full items-center gap-3 px-2">
              <button
                onClick={toggleSidebar}
                className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg hover:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                aria-label="Toggle navigation"
              >
                <PanelLeft className="h-4 w-4 text-muted-foreground" />
              </button>
              {!isCollapsed ? (
                <div className="min-w-0">
                  <span className="block truncate font-semibold tracking-[0.08em] text-primary">
                    FSL / QA
                  </span>
                  <span className="block font-mono text-[9px] uppercase tracking-[0.18em] text-muted-foreground">
                    Remote operator
                  </span>
                </div>
              ) : null}
            </div>
          </SidebarHeader>
          <SidebarContent className="gap-0">
            <SidebarMenu className="px-2 py-2">
              {menuItems.map(item => {
                const isActive = activeSection === item.section;
                return (
                  <SidebarMenuItem key={item.section}>
                    <SidebarMenuButton
                      isActive={isActive}
                      onClick={() => navigateTo(item.section)}
                      tooltip={item.label}
                      className="h-10 border border-transparent font-normal transition-all data-[active=true]:border-primary/30 data-[active=true]:bg-primary/10 data-[active=true]:shadow-[inset_2px_0_0_var(--primary)]"
                    >
                      <item.icon className={isActive ? "text-primary" : ""} />
                      <span>{item.label}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                );
              })}
            </SidebarMenu>
          </SidebarContent>
          <SidebarFooter className="border-t border-sidebar-border/70 p-3">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button className="flex w-full items-center gap-3 rounded-lg px-1 py-1 text-left hover:bg-accent/50 focus:outline-none focus-visible:ring-2 focus-visible:ring-ring group-data-[collapsible=icon]:justify-center">
                  <Avatar className="h-9 w-9 shrink-0 border border-primary/25">
                    <AvatarFallback className="bg-primary/10 text-xs text-primary">
                      {user?.name?.charAt(0).toUpperCase() || "O"}
                    </AvatarFallback>
                  </Avatar>
                  <div className="min-w-0 flex-1 group-data-[collapsible=icon]:hidden">
                    <p className="truncate text-sm font-medium">
                      {user?.name || "Owner operator"}
                    </p>
                    <p className="mt-1 truncate font-mono text-[9px] uppercase tracking-[0.12em] text-muted-foreground">
                      {user?.role ?? "authenticated"}
                    </p>
                  </div>
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-52">
                <DropdownMenuItem
                  onClick={logout}
                  className="cursor-pointer text-destructive focus:text-destructive"
                >
                  <LogOut className="mr-2 h-4 w-4" />
                  Sign out
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </SidebarFooter>
        </Sidebar>
        <div
          className={`absolute right-0 top-0 h-full w-1 cursor-col-resize hover:bg-primary/20 ${isCollapsed ? "hidden" : ""}`}
          onMouseDown={() => !isCollapsed && setIsResizing(true)}
          style={{ zIndex: 50 }}
        />
      </div>
      <SidebarInset>
        {isMobile ? (
          <div className="sticky top-0 z-40 flex h-14 items-center gap-2 border-b border-border bg-background/90 px-2 backdrop-blur-xl">
            <SidebarTrigger className="h-9 w-9 rounded-lg" />
            <span className="font-mono text-xs uppercase tracking-[0.12em] text-primary">
              {activeMenuItem?.label ?? "Operator"}
            </span>
          </div>
        ) : null}
        <main className="operator-grid min-h-screen flex-1 p-3 sm:p-5 lg:p-6">
          {children}
        </main>
      </SidebarInset>
    </>
  );
}
