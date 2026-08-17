import { describe, expect, test } from "bun:test";
import { buildStatusNotifications, classifyToastLine, statusFixture } from "../src";

describe("notification logic", () => {
  test("classifies OpenCode toast lines with the same severity ordering", () => {
    expect(classifyToastLine("[SECURITY ADVISORY] rotate token")).toBe("error");
    expect(classifyToastLine("[WARN] GitHub CLI prerequisite requires gh >= 2.51.0")).toBe("warning");
    expect(classifyToastLine("1 contribution need maintainer review")).toBe("warning");
    expect(classifyToastLine("2 contributions need maintainer review")).toBe("warning");
    expect(classifyToastLine("Contribution(s) needs maintainer review")).toBe("warning");
    expect(classifyToastLine("Security: all protections active")).toBe("success");
    expect(classifyToastLine("aidevops v3.29.0 running in OpenCode v1.17.11")).toBe("info");
    expect(classifyToastLine("UPDATE_AVAILABLE|3.30.0")).toBeNull();
  });

  test("builds colourable notification records and GUI action metadata", () => {
    const notifications = buildStatusNotifications({
      aiApps: statusFixture.ai_apps,
      greetingOutput: [
        "[SECURITY ADVISORY] Test advisory",
        "[OPENCODE MAINTENANCE] Archive recommended",
        "Security: all protections active",
      ].join("\n"),
      oauthPool: statusFixture.oauth_pool,
      restartRequired: true,
      setupTargets: statusFixture.setup_targets,
    });

    expect(notifications.map((notification) => notification.severity)).toContain("error");
    expect(notifications.map((notification) => notification.severity)).toContain("warning");
    expect(notifications.map((notification) => notification.severity)).toContain("success");
    expect(notifications.some((notification) => notification.actions.some((action) => action.kind === "surface" && action.enabled))).toBe(true);
    expect(notifications.find((notification) => notification.id === "gui-restart-required")?.status).toBe("active");
  });

  test("tolerates partially loaded GUI status payloads", () => {
    const notifications = buildStatusNotifications({
      greetingOutput: "Security: all protections active",
      restartRequired: false,
    } as Parameters<typeof buildStatusNotifications>[0]);

    expect(notifications).toHaveLength(1);
    expect(notifications[0]?.severity).toBe("success");
  });

  test("keeps provider notifications safe when the OAuth pool source path is absent", () => {
    const notifications = buildStatusNotifications({
      aiApps: [],
      greetingOutput: "",
		oauthPool: {
			path_ref: "",
			health: "present",
        providers: [{
          accounts: [],
          active_or_idle: 0,
          auth_errors: 1,
          available: 0,
          configured: true,
          pending_token: false,
          provider: "openai",
          rate_limited: 1,
          total: 1,
        }],
        value_policy: "metadata_only_no_tokens",
      },
      restartRequired: false,
      setupTargets: [],
    } as Parameters<typeof buildStatusNotifications>[0]);

    expect(notifications.filter((notification) => notification.source_ref === "oauth_pool")).toHaveLength(2);
  });
});
