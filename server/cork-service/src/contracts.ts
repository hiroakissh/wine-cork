import { z } from "zod";

export const uuid = z.string().uuid().transform(value => value.toLowerCase());
export const timestamp = z.string().datetime({ offset: true });
const text = z.string().max(10000);
const optionalText = text.nullable().default(null);
const score = z.number().int().min(0).max(5).nullable().default(null);
export const wineType = z.enum(["red", "white", "rose", "sparkling", "dessert", "fortified", "other"]);
export const lifecycle = z.enum(["owned", "opened", "finished"]);
export const tastingSchema = z.object({
  id: uuid, tastedAt: timestamp,
  rating: z.number().int().min(1).max(5).nullable().default(null),
  acidity: score, sweetness: score, tannin: score, body: score, alcohol: score, finish: score,
  aromaTags: z.array(z.string().max(100)).max(100).default([]),
  palateTags: z.array(z.string().max(100)).max(100).default([]), note: optionalText,
  servingTemperatureCelsius: z.number().finite().nullable().default(null),
  openedHoursBeforeTasting: z.number().nonnegative().nullable().default(null)
}).strict();
export const pairingSchema = z.object({
  id: uuid, tastingID: uuid.nullable().default(null), dishName: z.string().trim().min(1).max(200),
  dishCategory: optionalText, score: z.number().int().min(1).max(5), note: optionalText
}).strict();
export const eventSchema = z.object({
  id: uuid, fromState: lifecycle.nullable(), toState: lifecycle, occurredAt: timestamp, note: optionalText
}).strict();
export const bottleSchema = z.object({
  id: uuid, wineID: uuid, cellarID: uuid, name: z.string().trim().min(1).max(500),
  producer: optionalText, region: optionalText, country: optionalText,
  grapeVarieties: z.array(z.string().max(100)).max(100).default([]),
  vintage: z.number().int().min(1000).max(2999).nullable().default(null), wineType,
  volumeML: z.number().int().positive().max(100000).nullable().default(null),
  alcoholPercent: z.number().min(0).max(100).nullable().default(null),
  lifecycleState: lifecycle, storageLocation: optionalText,
  acquiredAt: timestamp.nullable().default(null), openedAt: timestamp.nullable().default(null),
  finishedAt: timestamp.nullable().default(null),
  remainingPercent: z.number().int().min(0).max(100).nullable().default(null), note: optionalText,
  bottleShape: z.enum(["bordeaux", "burgundy", "rhone", "alsace", "champagne", "generic"]),
  createdAt: timestamp, updatedAt: timestamp,
  tastings: z.array(tastingSchema).max(10000), pairings: z.array(pairingSchema).max(10000),
  events: z.array(eventSchema).max(10000)
}).strict().superRefine((bottle, ctx) => {
  for (const key of ["tastings", "pairings", "events"] as const) {
    if (new Set(bottle[key].map(item => item.id)).size !== bottle[key].length)
      ctx.addIssue({ code: "custom", message: `Duplicate ${key} IDs` });
  }
  const tastingIDs = new Set(bottle.tastings.map(item => item.id));
  if (bottle.pairings.some(item => item.tastingID && !tastingIDs.has(item.tastingID)))
    ctx.addIssue({ code: "custom", message: "Unknown pairing tastingID" });
});
export const patchSchema = z.object({
  storageLocation: text.nullable().optional(), note: text.nullable().optional(),
  remainingPercent: z.number().int().min(0).max(100).nullable().optional()
}).strict().refine(value => Object.keys(value).length > 0, "No changes supplied");
export const actionSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.enum(["create", "import"]), bottle: bottleSchema }).strict(),
  z.object({ kind: z.literal("patch"), patch: patchSchema }).strict(),
  z.object({ kind: z.literal("state"), state: lifecycle, occurredAt: timestamp.optional(), eventID: uuid }).strict(),
  z.object({ kind: z.literal("tasting"), tasting: tastingSchema }).strict(),
  z.object({ kind: z.literal("pairing"), pairing: pairingSchema }).strict(),
  z.object({ kind: z.literal("delete") }).strict()
]);
export const operationSchema = z.object({
  operationID: uuid, bottleID: uuid, baseVersion: z.number().int().nonnegative().safe(), action: actionSchema
}).strict();
export type Bottle = z.infer<typeof bottleSchema>;
export type Operation = z.infer<typeof operationSchema>;
export type Change = { bottleID: string; version: number; bottle: Bottle | null; cursor: number };
export type Principal = { owner: string; scopes: Set<string> };

export class ServiceError extends Error {
  constructor(public code: string, public status: number, public current?: Change) { super(code); }
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object")
    return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  return JSON.stringify(value);
}
