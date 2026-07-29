import { NextResponse } from "next/server";

/** Returns the browser-safe map display token at runtime. */
export function GET() {
  return NextResponse.json({ token: process.env.NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN || null });
}
