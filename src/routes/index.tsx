import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Counter POS Backend" },
      { name: "description", content: "Backend service for the Counter POS mobile app." },
      { property: "og:title", content: "Counter POS Backend" },
      { property: "og:description", content: "Backend service for the Counter POS mobile app." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: Index,
});

function Index() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-2xl font-semibold text-foreground">Counter POS Backend</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          This service powers the Counter POS mobile app. There is no web interface.
        </p>
      </div>
    </main>
  );
}
