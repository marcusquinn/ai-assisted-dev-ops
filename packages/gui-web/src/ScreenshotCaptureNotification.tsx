import { type ReactElement, useEffect, useRef, useState } from "react";

export interface ScreenshotCapturedDetail {
  path: string;
  url: string;
}

interface ScreenshotCapturedNotification extends ScreenshotCapturedDetail {
  id: number;
}

interface WebKitExternalLinkWindow extends Window {
  webkit?: {
    messageHandlers?: {
      externalLink?: {
        postMessage: (href: string) => void;
      };
    };
  };
}

export function ScreenshotCaptureNotification({ notification, onDismiss }: { notification: ScreenshotCapturedDetail; onDismiss: () => void }): ReactElement {
  const revealScreenshot = () => {
    const webkit = (window as WebKitExternalLinkWindow).webkit;
    webkit?.messageHandlers?.externalLink?.postMessage(notification.url);
  };

  return (
    <div className="screenshot-capture-notification" role="status">
      <span aria-hidden="true" className="screenshot-info-icon">i</span>
      <div>
        <strong>Screenshot captured</strong>
        <span className="screenshot-file-path-line"><span className="screenshot-file-path-label">Saved to:</span> <button className="screenshot-path-button" onClick={revealScreenshot} title={notification.path} type="button">{notification.path}</button></span>
        <span>File path copied to clipboard.</span>
      </div>
      <button aria-label="Dismiss screenshot notification" className="screenshot-dismiss-button" onClick={onDismiss} type="button">×</button>
    </div>
  );
}

export function ScreenshotCaptureNotificationHost(): ReactElement | null {
  const nextNotificationId = useRef(0);
  const [screenshotNotifications, setScreenshotNotifications] = useState<ScreenshotCapturedNotification[]>([]);

	useEffect(() => {
		const showScreenshotNotification = (event: Event) => {
			const detail = (event as CustomEvent<Partial<ScreenshotCapturedDetail>>).detail;
			const path = detail?.path;
			const url = detail?.url;
			if (typeof path === "string" && typeof url === "string") {
				nextNotificationId.current += 1;
				setScreenshotNotifications((current) => [...current, { id: nextNotificationId.current, path, url }]);
			}
		};

    window.addEventListener("aidevops:screenshot-captured", showScreenshotNotification);
    return () => window.removeEventListener("aidevops:screenshot-captured", showScreenshotNotification);
  }, []);

  return screenshotNotifications.length > 0 ? (
    <div className="screenshot-capture-notification-stack">
      {screenshotNotifications.map((notification) => (
        <ScreenshotCaptureNotification
          key={notification.id}
          notification={notification}
          onDismiss={() => setScreenshotNotifications((current) => current.filter((item) => item.id !== notification.id))}
        />
      ))}
    </div>
  ) : null;
}
