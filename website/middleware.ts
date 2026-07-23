import { trackAICrawlerRequest } from "@datafast/ai-crawl";

// Vercel Edge Middleware: fire-and-forget AI crawler tracking (DataFast).
// Do not await; returning nothing lets the static asset be served as usual.
export default function middleware(request: Request, event: { waitUntil: (p: Promise<unknown>) => void }) {
  trackAICrawlerRequest(request as never, event as never, {
    websiteId: "dfid_HMM2pp9guqaCpR3KioH9l",
  });
}

export const config = {
  matcher: "/((?!.*\\.(?:png|ico|svg|css|js|webmanifest|json|txt|xml|jpg|jpeg|gif|woff2?)).*)",
};
