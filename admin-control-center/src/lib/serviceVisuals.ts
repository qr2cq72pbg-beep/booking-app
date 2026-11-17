// Service pictures — the same catalogue, packs, suggestions and Macedonian names as the
// GT Termin app (index.html SERVICE_VISUALS / getSuggestedServiceVisualKeysForCategory /
// SERVICE_VISUAL_NAME_HINTS). Images are the app's own files in /assets/service-visuals/.
import { normalizeCategoryId } from "./configApi";

export type VisualPack = "barber" | "hair" | "beauty" | "nails" | "body" | "dentist";
export type ServiceVisual = { key: string; pack: VisualPack; label: string; src: string };

const ROOT = "/assets/service-visuals/";
const v = (key: string, pack: VisualPack, label: string): ServiceVisual => ({ key, pack, label, src: `${ROOT}${pack}/${key}.webp` });

export const SERVICE_VISUALS: ServiceVisual[] = [
  v("barber_haircut_01", "barber", "Шишање"),
  v("barber_hair_beard_01", "barber", "Коса и брада"),
  v("barber_shave_01", "barber", "Бричење"),
  v("hair_women_cut_01", "hair", "Дамско шишање"),
  v("hair_coloring_01", "hair", "Боја"),
  v("hair_styling_01", "hair", "Стилизирање"),
  v("hair_blowdry_01", "hair", "Фен"),
  v("hair_treatment_01", "hair", "Третман на коса"),
  v("nails_manicure_01", "nails", "Маникир"),
  v("nails_gel_01", "nails", "Гел нокти"),
  v("nails_art_01", "nails", "Неил арт"),
  v("nails_extensions_01", "nails", "Надоградба"),
  v("nails_pedicure_01", "nails", "Педикир"),
  v("nails_advanced_pedicure_01", "nails", "Напреден педикир"),
  v("beauty_makeup_01", "beauty", "Шминка"),
  v("beauty_lashes_01", "beauty", "Трепки"),
  v("beauty_eyebrows_01", "beauty", "Веѓи"),
  v("beauty_facial_01", "beauty", "Третман на лице"),
  v("beauty_skin_01", "beauty", "Кожа"),
  v("beauty_peeling_01", "beauty", "Пилинг"),
  v("beauty_waxing_01", "beauty", "Депилација"),
  v("beauty_laser_hair_removal_01", "beauty", "Ласерска депилација"),
  v("massage_relax_01", "body", "Релакс масажа"),
  v("massage_sports_01", "body", "Спортска масажа"),
  v("body_lymphatic_01", "body", "Лимфна"),
  v("body_anticellulite_01", "body", "Антицелулит"),
  v("body_maderotherapy_01", "body", "Мадеротерапија"),
  v("body_sculpting_01", "body", "Скулптурирање"),
  v("dentist_whitening_01", "dentist", "Белење"),
  v("dentist_treatment_01", "dentist", "Стоматолошки третман"),
];

export const VISUAL_TABS: Array<{ id: "suggested" | VisualPack | "all"; label: string }> = [
  { id: "suggested", label: "Предложени" },
  { id: "barber", label: "Бербер" },
  { id: "hair", label: "Коса" },
  { id: "beauty", label: "Убавина" },
  { id: "nails", label: "Нокти" },
  { id: "body", label: "Тело" },
  { id: "dentist", label: "Стоматолог" },
  { id: "all", label: "Сите" },
];

export const visualByKey = (key: string | null | undefined) => SERVICE_VISUALS.find((x) => x.key === key) || null;
const keysOf = (pack: VisualPack) => SERVICE_VISUALS.filter((x) => x.pack === pack).map((x) => x.key);
const uniq = (keys: string[]) => [...new Set(keys)].filter((k) => visualByKey(k));

/** Same as the app's getSuggestedServiceVisualKeysForCategory. */
export function suggestedVisualKeys(category: string | null | undefined): string[] {
  const id = normalizeCategoryId(category);
  const [hair, beauty, nails, body, dentist] = (["hair", "beauty", "nails", "body", "dentist"] as VisualPack[]).map(keysOf);
  if (id === "barber") return uniq(["barber_haircut_01", "barber_hair_beard_01", "barber_shave_01"]);
  if (id === "hair-salon") return uniq([...hair, "beauty_makeup_01", "beauty_eyebrows_01", "beauty_lashes_01"]);
  if (id === "beauty-salon" || id === "aesthetics-clinic" || id === "cosmetic-studio") return uniq([...beauty, ...nails, ...body, ...hair]);
  if (id === "eyebrows-lashes") return uniq(["beauty_eyebrows_01", "beauty_lashes_01", ...beauty]);
  if (id === "nail-studio") return uniq(nails);
  if (id === "makeup-artist") return uniq(["beauty_makeup_01", "beauty_eyebrows_01", "beauty_lashes_01"]);
  if (id === "massage-therapy" || id === "spa-wellness" || id === "physiotherapy" || id === "chiropractic") {
    return uniq([...body, "beauty_waxing_01", "beauty_laser_hair_removal_01"]);
  }
  if (id === "dental-clinic") return uniq(dentist);
  return SERVICE_VISUALS.map((x) => x.key);
}

const NAME_HINTS: Array<{ re: RegExp; key: string }> = [
  { re: /(laser|ласер).{0,32}(hair|depil|epil|кос|депил|епил)|(hair|depil|epil|депил|епил).{0,32}(laser|ласер)/i, key: "beauty_laser_hair_removal_01" },
  { re: /wax|восок|депил|depila|epilat|epilac|dyll/i, key: "beauty_waxing_01" },
  { re: /whitening|белење|белене|teeth\s*white|zbardh/i, key: "dentist_whitening_01" },
  { re: /dental\s*treat|стоматолог.{0,16}третман|стоматолошки|dentist|dental|стоматолог|заб|dhëmb|dhemb/i, key: "dentist_treatment_01" },
  { re: /anticell|антицелул|anti[\s-]?cell/i, key: "body_anticellulite_01" },
  { re: /lymph|лимфн|лимфна|lymphatic|lymph\s*drain/i, key: "body_lymphatic_01" },
  { re: /madero|мадеро/i, key: "body_maderotherapy_01" },
  { re: /sculpt|обликување.{0,12}тело|body\s*sculpt|кавитац|cavitat/i, key: "body_sculpting_01" },
  { re: /sport.{0,16}mass|спортск.{0,16}масаж|\bsport/i, key: "massage_sports_01" },
  { re: /relax.{0,16}mass|релакс.{0,16}масаж|massage|масаж|masazh/i, key: "massage_relax_01" },
  { re: /eyebrow|веѓ|веги|vetull|\bbrows\b/i, key: "beauty_eyebrows_01" },
  { re: /lash|трепк|qerpik/i, key: "beauty_lashes_01" },
  { re: /peel|пилинг/i, key: "beauty_peeling_01" },
  { re: /facial|лице|fytyr/i, key: "beauty_facial_01" },
  { re: /makeup|шминк|grim/i, key: "beauty_makeup_01" },
  { re: /\bgel\b|гел/i, key: "nails_gel_01" },
  { re: /extension|надоград|надград|zgjat/i, key: "nails_extensions_01" },
  { re: /nail\s*art|неил\s*арт/i, key: "nails_art_01" },
  { re: /advanced.{0,12}pedi|аванс.{0,8}педик/i, key: "nails_advanced_pedicure_01" },
  { re: /pedi|педик|pedikyr/i, key: "nails_pedicure_01" },
  { re: /mani|маник|manikyr/i, key: "nails_manicure_01" },
  { re: /color|colour|фарб|боење|боен|боја|bojë|highlight|балејаж|balayage/i, key: "hair_coloring_01" },
  { re: /blow\s*dry|blowdry|фенир|фен|tharje/i, key: "hair_blowdry_01" },
  { re: /styl|стилиз|фризур/i, key: "hair_styling_01" },
  { re: /keratin|kerat|третман.{0,12}кос|hair\s*treat/i, key: "hair_treatment_01" },
  { re: /women|дамск|женск|femra/i, key: "hair_women_cut_01" },
  { re: /beard|брада|mjekër/i, key: "barber_hair_beard_01" },
  { re: /shave|бричење|бричене|rroj/i, key: "barber_shave_01" },
  { re: /fade|фејд/i, key: "barber_haircut_01" },
  { re: /haircut|шишање|шишане|prerje|\bcut\b/i, key: "barber_haircut_01" },
];

/** Same as the app's suggestServiceVisualKeyFromName. */
export function suggestVisualFromName(name: string, category: string | null | undefined): string {
  const raw = name.trim();
  if (!raw) return "";
  for (const hint of NAME_HINTS) {
    if (!hint.re.test(raw)) continue;
    if (hint.key === "barber_haircut_01" && !/fade|фејд/i.test(raw) && normalizeCategoryId(category) === "hair-salon") return "hair_women_cut_01";
    return hint.key;
  }
  return "";
}
