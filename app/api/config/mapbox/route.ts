import { NextResponse } from "next/server";

/** Returns the browser-safe map display token at runtime. */
export function GET() {
  return NextResponse.json({ token: process.env.MAPBOX_BROWSER_TOKEN || null });
}
