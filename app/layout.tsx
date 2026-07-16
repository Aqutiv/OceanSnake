import type { Metadata, Viewport } from "next";

export const metadata: Metadata = {
  title: "Ocean Snake",
  description: "A responsive ocean-themed snake game.",
};

export const viewport: Viewport = {
  themeColor: "#0b5d87",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
