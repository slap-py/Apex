import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = { title: "Apex Pace Notes", description: "Plan a route and inspect rally-style curve calls." };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="en"><body>{children}</body></html>; }
