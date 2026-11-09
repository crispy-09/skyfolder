import {
  Folder, FileText, Sheet, Presentation, FileType2, Image, Film, Music, FileArchive, FileCode, File, AlignLeft,
} from "@lucide/svelte";

const ext = (name) => {
  const i = name.lastIndexOf(".");
  return i > 0 ? name.slice(i + 1).toLowerCase() : "";
};

const sets = {
  document: ["doc", "docx", "odt", "rtf", "pages"],
  spreadsheet: ["xls", "xlsx", "ods", "csv", "tsv", "numbers"],
  presentation: ["ppt", "pptx", "odp", "key"],
  pdf: ["pdf"],
  image: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "heic", "heif", "tif", "tiff", "avif", "raw", "cr2", "nef"],
  video: ["mp4", "mov", "mkv", "webm", "avi", "m4v", "wmv", "flv"],
  audio: ["mp3", "wav", "flac", "ogg", "m4a", "aac", "opus"],
  archive: ["zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz", "dmg", "iso"],
  code: ["js", "ts", "json", "yml", "yaml", "xml", "html", "css", "sh", "py", "rs", "go", "swift", "c", "cpp", "h", "java", "lua", "toml"],
  text: ["txt", "md", "log", "ini", "cfg"],
};

export const KINDS = {
  folder: { label: "Folders", type: "Folder", color: "#5f6368", icon: Folder },
  document: { label: "Documents", type: "Document", color: "#4285f4", icon: AlignLeft },
  spreadsheet: { label: "Spreadsheets", type: "Spreadsheet", color: "#0f9d58", icon: Sheet },
  presentation: { label: "Presentations", type: "Presentation", color: "#f4b400", icon: Presentation },
  pdf: { label: "PDFs", type: "PDF", color: "#ea4335", icon: FileType2 },
  image: { label: "Photos & images", type: "Image", color: "#ea4335", icon: Image },
  video: { label: "Videos", type: "Video", color: "#ea4335", icon: Film },
  audio: { label: "Audio", type: "Audio", color: "#9334e6", icon: Music },
  archive: { label: "Archives (zip)", type: "Archive", color: "#5f6368", icon: FileArchive },
  code: { label: "Code", type: "Code", color: "#5f6368", icon: FileCode },
  text: { label: "Text", type: "Text", color: "#4285f4", icon: FileText },
  other: { label: "Other", type: "File", color: "#5f6368", icon: File },
};

export function kindOf(item) {
  if (item.isFolder) return "folder";
  const e = ext(item.name);
  for (const [k, list] of Object.entries(sets)) if (list.includes(e)) return k;
  const ct = item.contentType || "";
  if (ct.startsWith("image/")) return "image";
  if (ct.startsWith("video/")) return "video";
  if (ct.startsWith("audio/")) return "audio";
  if (ct.startsWith("text/")) return "text";
  return "other";
}

export const extOf = ext;

export function canThumbnail(item) {
  if (item.hasPreview) return true;
  const e = ext(item.name);
  return ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "avif"].includes(e) && item.size > 0 && item.size < 8_000_000;
}

export function formatBytes(n) {
  if (!n) return "0 bytes";
  const u = ["bytes", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = n;
  while (v >= 1000 && i < u.length - 1) {
    v /= 1000;
    i++;
  }
  return `${i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)} ${u[i]}`;
}

export function shortDate(secs) {
  if (!secs) return "—";
  const d = new Date(secs * 1000);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  if (d.getFullYear() === now.getFullYear()) return d.toLocaleDateString([], { month: "short", day: "numeric" });
  return d.toLocaleDateString([], { month: "short", day: "numeric", year: "numeric" });
}

export function longDate(secs) {
  if (!secs) return "—";
  return new Date(secs * 1000).toLocaleString([], { dateStyle: "long", timeStyle: "short" });
}
