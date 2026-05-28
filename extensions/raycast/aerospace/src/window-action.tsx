import { List, Action, ActionPanel, showToast, Toast, LaunchProps, closeMainWindow } from "@raycast/api";
import { execSync } from "child_process";
import { useState, useEffect } from "react";

const AEROSPACE = "aerospace";

interface WindowInfo {
  id: number;
  title: string;
  workspace: string;
}

interface LaunchContext {
  bundleId: string;
  appName: string;
  bundlePath: string;
  windows: WindowInfo[];
}

function run(cmd: string): string {
  return execSync(cmd, { encoding: "utf-8" }).trim();
}

export default function WindowAction(props: LaunchProps<{ launchContext: LaunchContext }>) {
  const ctx = props.launchContext;
  const [currentWorkspace, setCurrentWorkspace] = useState<string>("");

  useEffect(() => {
    try {
      setCurrentWorkspace(run(`${AEROSPACE} list-workspaces --focused`));
    } catch {
      showToast({ style: Toast.Style.Failure, title: "Failed to get current workspace" });
    }
  }, []);

  if (!ctx) {
    return <List><List.EmptyView title="No context" description="This command is launched via AeroSpace" /></List>;
  }

  return (
    <List navigationTitle={ctx.appName}>
      <List.Item
        title="New Window"
        icon="plus-circle"
        actions={
          <ActionPanel>
            <Action
              title="Open New Window"
              onAction={async () => {
                try {
                  run(`open -n "${ctx.bundlePath}"`);
                  await closeMainWindow();
                } catch {
                  showToast({ style: Toast.Style.Failure, title: "Failed to open new window" });
                }
              }}
            />
          </ActionPanel>
        }
      />
      {ctx.windows.map((w) => (
        <List.Item
          key={w.id}
          title={w.title || `Window ${w.id}`}
          subtitle={`workspace ${w.workspace}`}
          actions={
            <ActionPanel>
              <Action
                title="Move to Current Workspace"
                onAction={async () => {
                  try {
                    run(`${AEROSPACE} move-node-to-workspace --window-id ${w.id} ${currentWorkspace}`);
                    run(`${AEROSPACE} focus --window-id ${w.id}`);
                    await closeMainWindow();
                  } catch {
                    showToast({ style: Toast.Style.Failure, title: "Failed to move window" });
                  }
                }}
              />
              <Action
                title="Focus on Its Workspace"
                onAction={async () => {
                  try {
                    run(`${AEROSPACE} workspace ${w.workspace}`);
                    run(`${AEROSPACE} focus --window-id ${w.id}`);
                    await closeMainWindow();
                  } catch {
                    showToast({ style: Toast.Style.Failure, title: "Failed to focus workspace" });
                  }
                }}
              />
              <Action
                title="Close Window"
                shortcut={{ modifiers: ["cmd"], key: "d" }}
                onAction={async () => {
                  try {
                    run(`${AEROSPACE} close --window-id ${w.id}`);
                    await closeMainWindow();
                  } catch {
                    showToast({ style: Toast.Style.Failure, title: "Failed to close window" });
                  }
                }}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
