import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Stint — Live racing. Deeper insights.",
  description:
    "More than a race. Every stint. A native, map-first race viewer for Mac and iPad with real telemetry on a 3D globe.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
