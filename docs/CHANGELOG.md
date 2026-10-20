# Changelog and developer notes (Taglish)

_(dating "DarkLab Studio", at bago noon "Darkroom")_

Offline photo library + RAW editor para sa macOS, inspired ng Lightroom Classic.
SwiftUI + SQLite + Core Image. Walang account, walang cloud.

**Bago sa v0.28.0: Match Total Exposures + Client Proofing Gallery**
- **Photo ▸ Match Total Exposures (⌥⇧⌘M)** (pati right-click ▸ Develop Settings at ⌘K): piliin ang serye, i-click ang photo na tama ang liwanag, at ita-tama ang **Exposure** ng iba batay sa shutter, aperture at ISO (gaya ng Lightroom). Exposure lang ang nagbabago; nilalaktawan ang walang camera data.
- **File ▸ Create Proofing Gallery…** (o right-click ▸ Export): gagawa ng folder + **.zip** (website ng mga napiling photo, 1600/2048/2560 px, may watermark kung gusto) na bubuksan ng kliyente sa browser kahit walang internet. Hearts, notes, Favorites filter, malaking view (←/→, swipe), at **Send my picks** (Copy, email, o Messenger).
- **File ▸ Import Client Picks…**: i-paste ang listahan ng kliyente → **Purple** label sa mga favorite nila (hindi gagalawin ang sarili mong flags at stars). Lalabas ang notes nila na may **Show** button; **Show Client Picks** = Library Filter ▸ Purple.
- Naka-save sa `~/Library/Application Support/Darkroom/Proofing/` ang listahan ng bawat gallery para tamang photo ang ma-match kahit pareho ang file name.

**Bago sa v0.27.1: Open source**
- Open source na sa GitHub (LumaGrader/photo-studio) sa ilalim ng **GNU GPL v3** (`LICENSE`). English na `README.md`; ang Taglish na notes na ito ay nasa `docs/CHANGELOG.md` na.
- About tab: bagong **Website** (lumagrader.app) at **Source Code** buttons, License row; "© LumaGrader (Rax). Free software, GNU GPL v3." (dating "All rights reserved", na hindi tugma sa GPL).

**Bago sa v0.27.0: Bagong pangalan — LumaGrader Photo Studio**
- Bahagi na ng **LumaGrader** suite (LumaGrader Photo Studio · LumaGrader Motion · for iPad). May kapangalang "DarkLab Studio" na website, kaya pinalitan.
- App: `LumaGrader Photo Studio.app` (sa Dock at Applications); "LumaGrader" sa menu bar. Wordmark: "Luma" puti + "Grader" asul + PHOTO STUDIO.
- Icon: ang **LumaGrader "L"** na logo (pareho sa lumagrader.app), sa app icon, top bar, Guide at DMG.
- Installer: `dist/LumaGrader-Photo-Studio-<version>.dmg` (+ .zip para sa Ko-fi).
- Kusang tinatanggal ng `make-app.sh --install` ang lumang `DarkLab.app` at `Darkroom.app`.
- **Walang nawawala:** pareho ang bundle id at ang catalog folder (`~/Library/Application Support/Darkroom`), kaya andiyan pa rin ang photos, edits, presets at settings. Kung ginagamit ang `~/Pictures/DarkLab Tether`, iyon pa rin ang tether folder (para tugma pa sa EOS Utility).
- Ko-fi: **ko-fi.com/lumagrader** (pinalitan ni Rax ang Ko-fi page: "LumaGrader Studio").

**Bago sa v0.26.0: Delete Photo + right-click sa preview**
- **Delete Photo…** (right-click, ⌫ Delete key, Photo menu, ⌘K): may tanong gaya ng Lightroom — **Move to Trash** (buburahin ang file; mababawi pa sa Trash) o **Remove from Catalog** (maiiwan ang file, aalisin lang sa DarkLab). Kasama ang naka-stack na JPEG ng RAW, at ang mga virtual copy ng photo. Virtual copy lang ang napili → aalisin lang sa catalog.
- Pagkatapos mag-delete, susunod na photo ang lalabas (nananatili sa Loupe/Develop).
- **Right-click sa malaking photo** sa Loupe, Develop, Compare at Survey (dati sa Grid at filmstrip lang). Sa Survey, ang na-right-click na photo ang gagawing aktibo.
- Sa Develop: ang ⌫ ay pang-delete pa rin ng healing spot kapag bukas ang Healing; walang epekto habang Masking o Crop.

**Bago sa v0.25.1**
- Ko-fi link → **ko-fi.com/darklabstudio** (bagong DarkLab page).
- `make-dmg.sh` gumagawa na rin ng `.zip` ng DMG (tinatanggihan ng Ko-fi Shop ang .dmg).

**Bago sa v0.25.0: Ko-fi Support**
- **Support** button (Ko-fi red, ☕) sa itaas-kanan, katabi ng Library · Develop · Print → ko-fi.com/darklabstudio.
- **Pagkatapos mag-export**: card na "Your photos are exported — Enjoying DarkLab?" na may Support on Ko-fi / Show in Finder / Maybe later. Isang beses lang kada linggo lumalabas.
- Nasa Help menu, ⌘K ("donate") at About din.
- Palitan ang Ko-fi page: `Support.kofiUsername` sa `Views/SupportViews.swift` (walang laman = nakatago lahat).

**Bago sa v0.24.0: Auto-Rotate Portraits**
- Kapag naka-off ang auto-rotate ng camera, nase-save nang patagilid ang vertical shots. Ngayon, **kusang itinatayo ng DarkLab** ang mga ito pagka-Import, Add Folder, Synchronize Folder, at bawat tethered shot.
- Paano: sinusuri lang ang mga file na walang orientation mula sa camera. Hinahanap ng Mac (on-device Vision) kung saang direksyon nakatayo ang mga mukha at tao, at doon iniikot. Mga photo na walang tao (landscape, wildlife) ay hindi ginagalaw.
- Quarter turn lang sa develop settings (hindi binabago ang file). Kung mali, ⌘[ / ⌘] para ibalik. Hindi nito pinapalitan ang ikot na ginawa mo na.
- **Photo ▸ Auto-Rotate Portraits**: suriin ulit ang mga napili. **Photo ▸ Auto-Rotate Portraits on Import**: i-off ang automatic (on by default). Progress sa itaas habang sumusuri.

**Bago sa v0.23.0: DarkLab Signature look**
Lightroom-style pa rin ang layout, pero may sariling DarkLab na itsura (maliliit na pagbabago):
- **Deep slate na kulay**: mga gray na may bahid ng navy ng logo (#011326), sa halip na neutral na gray ng Lightroom.
- **Module switcher na pill** (Library · Develop · Print, may icon) na may asul na guhit sa aktibo, kapalit ng "Library | Develop" na text.
- **Panel headers**: chevron na umiikot (asul kapag bukas) at manipis na **asul na gilid** sa kaliwa ng nakabukas na panel.
- **Sliders**: bilog na knob (may asul na singsing habang dina-drag), at ang centred sliders ay napupuno ng **asul** mula sa zero.
- **Grid at filmstrip**: rounded na cells; ang aktibong photo ay may **asul na outline**, ang napili ay slate-blue.
- Mas rounded na buttons (Import…, Export…, atbp.).

**Bago sa v0.22.0: DarkLab Guide**
- **Help ▸ DarkLab Guide (⇧⌘/)**, o ang **?** sa itaas-kanan. Tatlong tab:
  - **Features**: tutorial ng bawat feature (Import, Rate/Flag/Label, Survey, Focus Check, AI Cull, People, Basic + Auto, Masking, Healing/Denoise/Lens Blur, Presets/Sync, HDR, Export, Print, Tether, Catalog Backup), may steps, shortcuts at tips, at may search.
  - **Mac Security**: bakit normal na hinaharangan ng macOS ang DarkLab sa unang bukas (hindi notarized dahil walang paid Apple Developer ID), at paano ito payagan (Open Anyway; Sonoma right-click ▸ Open; "damaged" → xattr command na may Copy button). May button para buksan ang Privacy & Security.
  - **About**: version, gumawa, requirements, kung saan naka-save ang data.
- Lumalabas nang kusa ang Guide sa **unang bukas** ng app (para sa kaibigan o kliyenteng nag-install). "About DarkLab" sa app menu ay bumubukas sa About tab.
- Mas malinaw na paliwanag sa "Read Me First.txt" ng installer na normal ang babala ng macOS.

**Bago sa v0.21.0: Tether Develop Settings**
- Sa Start Tethered Capture… at sa **tether bar**: **Develop** menu para sa bawat bagong shot:
  - **None**: walang settings (gaya dati).
  - **Same as Previous**: i-edit ang isang shot (hal. exposure, WB, profile, crop), at kusang susunod ang mga kasunod. Kinokopya ang lahat maliban sa Spot Removal at Masks. Sa simula ng session, ang pinakabagong photo sa folder ang "previous".
  - **Kahit anong Develop preset** mo.
- Naa-apply bago ipakita, kaya edited na agad ang lumalabas sa Loupe/Develop. Puwedeng palitan habang nagte-tether.

**Bago sa v0.20.0: Focus Check**
- **Focus Peaking (⇧F**, o ang ⊙ "scope" button sa toolbar ng Loupe/Compare/Survey): pula ang mga bahaging nasa focus. Sa Survey, makikita agad kung alin sa burst ang matalas. Sensitivity: Photo ▸ Focus Peaking Sensitivity (Low / Medium / High). Mas eksakto kapag naka-zoom (gamit ang full-resolution na file).
- **Zoom to Sharpest Area (⇧Z**, o ang viewfinder button sa Loupe): diretso sa 100% sa pinakamatalas na bahagi ng photo, para i-check ang mata ng ibon o ng bride.
- Sa ⌘K: "focus".

**Bago sa v0.19.1**
- **Auto (Basic ▸ Tone) ay toggle na**: unang click = Auto Tone (nagiging asul ang "Auto"); i-click ulit (o ⌘U) = ibabalik ang Exposure, Contrast, Highlights, Shadows, Whites at Blacks sa dati bago ang Auto. Kapag ginalaw mo ang isa sa mga slider na iyon, bagong Auto ulit ang susunod na click. Puwede ring ⌘Z.

**Bago sa v0.19.0: Tethered Capture**
- **File ▸ Tethered Capture ▸ Start Tethered Capture…** (o ⌘K "tether"): "hot folder" na paraan. Ang **EOS Utility** ng Canon (libre) ang kumokontrol sa R8 (USB o Wi-Fi, Remote Shooting, live view), at ang DarkLab ang nagbabantay sa folder: bawat bagong shot ay kusang naidadagdag sa catalog at **ipinapakita agad nang malaki** (Loupe; kung nasa Develop ka, doon pa rin).
- Folder: `~/Pictures/DarkLab Tether/<yyyy-MM-dd> <Session>` (puwedeng palitan). May **Copy Path** para i-paste sa EOS Utility ▸ Preferences ▸ Destination Folder (⇧⌘G sa folder dialog), at **Open EOS Utility** kung naka-install.
- Hinihintay munang matapos isulat ang file bago ipakita. Gumagana kahit gumawa ang EOS Utility ng subfolders.
- **Tether bar** sa itaas ng photo: bilang ng shots, huling file, **Show New** (i-off kapag nire-review mo ang lumang shots), Finder, **Stop**.
- Gumagana rin sa ibang camera/app na nagse-save sa folder (Nikon NX Tether, Sony Imaging Edge, Wi-Fi/FTP).

**Bago sa v0.18.0: Print**
- **Print module** (Library | Develop | **Print** sa itaas, ⌥⌘P): Single Image layout, isang photo bawat page (kapag marami ang napili, isang page bawat isa).
  - **Page:** printer at papel; Page Setup… (⇧⌘P) para sa size at orientation.
  - **Layout:** Fit (buo ang photo) o Fill (crop hanggang margins), Rotate to Fit, margins (inches), Equal / Borderless, Border (black/white), Show Guides (asul = margins, pula = abot ng printer).
  - **Print Job:** resolution (240–720 ppi), print sharpening (Low/Standard/High, Matte/Glossy), **Print Adjustment** (Brightness/Contrast para sa print lang, kapag madilim ang labas ng print).
  - **Color Management:** ang DarkLab ang nagma-manage ng kulay. Pumili ng **ICC paper profile** (kusang hinahanap sa ColorSync at printer drivers; **Add Profile…** para sa profile na na-download sa Hahnemühle, Canson, Ilford, atbp.), Intent Perceptual/Relative, at **Simulate Paper & Ink** (soft proof sa preview, pati kulay ng papel). Sa print dialog, i-**Off** ang color management ng printer (Epson: Color Settings ▸ Off (No Color Adjustment); Canon: Color Mode ▸ None).
  - Babala sa ibaba kapag kulang ang pixels ng file para sa laki ng print (mababa sa 180 ppi).
  - File ▸ Print… (⌘P) mula kahit saan, gamit ang huling Print settings.
- **Masking / Healing auto-Done**: kapag nag-click ka ng ibang Develop section (Basic, Tone Curve, …) o binuksan ito sa ⌘K, kusang nagsasara ang Masking / Healing tool. Nananatili ang masks at spots.
- **Catalog Backup: off by default** na ang araw-araw na backup. I-on sa File ▸ Catalog Backup ▸ Back Up Daily.

**Bago sa v0.17.0: Installer + Catalog Backup**
- **Installer (DMG) para ibahagi**: `bash ./scripts/make-dmg.sh` → `dist/DarkLab-Studio-0.17.0.dmg`. Pag binuksan, may DarkLab, Applications shortcut (i-drag lang), at "Read Me First.txt" na nagtuturo kung paano buksan ang app sa unang beses (System Settings ▸ Privacy & Security ▸ Open Anyway), dahil hindi ito notarized ng Apple. Universal (Apple silicon + Intel); `--native` para mas mabilis na build para sa chip lang ng Mac mo. Sa unang run, payagan ang Terminal na i-control ang Finder (para sa ayos ng window).
- **Catalog Backup** (File ▸ Catalog Backup, o ⌘K "backup"): backup ng catalog **isang beses kada araw** kapag naka-on ang Back Up Daily (ilang segundo pagkabukas ng app), 10 pinakabagong kopya ang itinatabi, at bawat kopya ay sinusuri (quick_check). Back Up Now, Choose Backup Folder… (mas ligtas sa ibang drive; kapag naka-unplug, sa default folder muna), Show Backups in Finder, at **Restore from Backup…**: magre-reopen ang app gamit ang backup, at ang dating catalog ay itinatabi bilang "Catalog before restore.sqlite".
- `make-app.sh --universal` para sa Apple silicon + Intel na build.

**Bago sa v0.16.0: DarkLab Studio**
- Bagong pangalan: **DarkLab Studio** ("DarkLab" sa menu bar at Dock). Ang app ay `DarkLab.app`; tinatanggal ng installer ang lumang `Darkroom.app`. Pareho pa rin ang catalog, presets at settings (walang mawawala).
- Bagong icon at wordmark sa **istilo at kulay ng LumaGrader**: makapal na asul na outline, navy na tile, geometric na light-blue "D" na may diagonal na hiwa (asul na piraso); wordmark "Dark" puti + "Lab" asul.
- **Neutral pro look**: graphite na gray, maliliit na naka-uppercase na panel titles, at isang accent lang — ang **asul ng LumaGrader logo** — para sa aktibong tool, switches at progress.

**Bago sa v0.15.0**
- **Import Photos (⇧⌘I, o Import… sa kaliwa)**: kusang nakikita ang camera card (may DCIM). Kinokopya (hindi inililipat) sa `Main folder/<taon>/<petsa> <Shoot name>/`, pinapalitan ang pangalan ng `2026-10-13_Game_0001.CR3` (magkapareho ang numero ng RAW+JPEG), may **backup copy** sa ibang drive, nilalaktawan ang mga na-import na dati, at puwedeng maglapat ng preset + Creator/Copyright/Keywords. May progress sa itaas (may Stop) at puwedeng i-eject ang card pagkatapos. Ang lumang paraan ay nasa "Add Folder Without Copying…".

**Bago sa v0.14.0**
- **Auto Sync**: kapag maraming photo ang napili, i-on ang **Auto** switch sa tabi ng Sync… (kaliwang ibaba ng Develop) o Photo ▸ Auto Sync (⌥⇧⌘A). Bawat edit sa aktibong photo ay mapupunta rin sa lahat ng napili. May "Auto Sync · N photos" na badge habang naka-on.
- **Survey view (N)**: lahat ng napiling photo magkakatabi para piliin ang pinakamaganda sa burst. I-click para gawing aktibo; P / X / 1–5 / 6–9 para sa aktibong photo lang; ← → para lumipat; ✕ para alisin sa survey.

**Bago sa v0.13.0**
- **Mas mabilis lumipat ng photo sa Develop**: inihahanda na sa background ang susunod at naunang photo (pati ang kaka-alis mo lang), kaya halos instant ang ← →.
- **Mas mabilis na sliders**: habang gumagalaw ang Exposure, Contrast, HSL atbp., hindi na inuulit ang RAW decode/denoise/profile — kina-cache bilang pixels.
- **Solo Mode**: right-click sa header ng anumang Develop panel ▸ Solo Mode — isang panel lang ang bukas.
- **Command Palette (⌘K)**: i-type ang kahit anong command, panel o slider ("exposure", "export", "hdr", "red label", pangalan ng preset) at Return.

**Bago sa v0.12.1**
- **People (face tagging)**: Photo ▸ Find Faces (o ang People window) — hinahanap ng Mac ang mga mukha sa mga photo na nasa grid (on-device). Sa **People** window (Photo ▸ People…, o ang icon sa People section sa kaliwa), pinagsasama-sama ang magkakamukhang mukha; i-type ang pangalan at Name, o "Yes" kung tama ang hula ("Is this Ana?"). I-click ang tao sa kaliwa (o ang Person filter) para makita lang ang mga photo niya. Nasa Metadata panel din ang mga pangalan. *Approximate ito* — walang public face-recognition API ang macOS, kaya i-check ang bawat group bago pangalanan; may "Grouping" slider para sa higpit.

**Bago sa v0.12.0**
- **HDR Merge** (Photo ▸ Photo Merge ▸ HDR…, ⌃H, o right-click ▸ Photo Merge): pumili ng 2–9 bracketed shots ng parehong eksena. Options: Auto Align (para sa handheld), Auto Settings (Auto Tone pagkatapos), Deghost Amount (None/Low/Medium/High). Ang resulta ay 16-bit float TIFF ("<pangalan>-HDR.tif") sa tabi ng originals, idinadagdag sa catalog at pinipili. Ang highlights na lampas sa puti ay nasa file pa rin — ibalik gamit ang Exposure / Highlights / Whites.

**Bago sa v0.11.3**
- **Color labels**: 6 Red, 7 Yellow, 8 Green, 9 Blue (Purple sa right-click menu). Pindutin ulit para tanggalin. Makikita bilang kulay sa ilalim ng Grid cell at filmstrip, may Label filter sa Library Filter, at nasa Metadata panel. Gumagana sa lahat ng napiling photos.

**Bago sa v0.11.2**
- **Healing fix (2nd)**: ang spots ay ginagawa na sa isang rendered na kopya ng photo, isang pass sa buong frame (wala nang maliit na patch na idinidikit).
- **Lens Blur**: wala nang maliwanag na halo sa paligid ng subject — ang background fill ay kumukuha na ng kulay na pinakamalapit, hindi ng average ng buong paligid; mas manipis ang matalas na gilid.

**Bago sa v0.11.1**
- **Healing fix**: hindi na nasisira ang buong photo pag naglagay ng spot (Heal at Clone).
- **Denoise mas mabilis**: isang beses lang kino-compute; ang ibang sliders ay hindi na nagre-recompute ng denoise.
- **Lens Blur mas natural**: malambot ang gilid ng subject, at may "ground plane" — matalas ang sahig malapit sa paa, palabo habang lumalayo.

**Bago sa v0.11.0**
- **Right-click menu** (Grid at filmstrip), parang Lightroom: Export ▸ (Export…, Export with Previous, bawat export preset), Develop Settings ▸ (Auto, Copy/Paste, Paste from Previous, Sync, B&W, Reset), Develop Preset, Set Flag, Set Rating, Rotate, Virtual Copy, Collections, Show in Finder, Open in Default App, Copy File Path. Kapag maraming photo ang napili, para sa **lahat ng napili** ang gagawin.
- **Multi-select kahit saan**: ⌘-click / ⇧-click sa Grid **at** sa filmstrip (pati sa Develop). Edit ▸ Select None (⌘D), Select Picks, Invert Selection. Ang Export button sa kaliwa ay nagsasabi kung ilan ("Export 12…").
- **Batch shortcuts**: ⌥⌘C Copy All, ⇧⌘V Paste, ⌥⌘V Paste from Previous, ⇧⌘S Sync, ⌘U Auto Tone, ⇧⌘U Auto WB, ⌥⌘U Auto Tone + WB, ⇧⌘R Reset, ⌘[ / ⌘] Rotate. Gumagana sa Grid para sa lahat ng napili. Ang batch Auto ay may progress sa itaas (may Stop).
- **Healing (Q)**: Heal / Clone spots. I-click ang dumi o pimple; pipili si Darkroom ng katugmang area. I-drag ang bilog o ang dashed source. Delete = bura, [ ] = size.
- **Denoise** (Detail panel): edge-aware GPU denoise para sa high-ISO, may Amount at Detail. Tingnan sa 100% (Z).
- **Lens Blur** (bagong panel): blur sa background na may bokeh (Circle / Bubble / Soft), Boost para sa highlights, Edge Softness. Gamit ang Select Subject, o ang depth map ng iPhone Portrait photos (may Focus Distance at Range).
- Puwedeng mag-export ulit habang may tumatakbong export: idinadagdag ito sa pila.

**Mula sa v0.10.1**
- Tinanggal ang accent colors sa headers. Ang natira ay ang **may kulay na tuldok** sa section na may binago.
- **Watermark preview** sa Export (ipinapakita sa unang photo).
- **Batch export:** piliin ang photos (Selected / All shown / Picks), at puwedeng i-tick ang ilang **export presets** nang sabay. Halimbawa: full size + Instagram, kaya dalawang file bawat photo. Tumatakbo ito sa background (2 photo nang sabay) at nasa itaas ang progress, kaya puwedeng ituloy ang trabaho habang nag-e-export.

**Mula sa v0.10.0**
- May may-kulay na tuldok ang Develop section kapag may binago ka roon.
- **Collections** (Library, kaliwa): pagsamahin ang photos mula sa iba't ibang folder. Right-click ang photos → Add to Collection, o + → New Collection from Selection.
- **Virtual Copies** (⌘' o right-click → Create Virtual Copy): parehong file pero sariling edit, may "VC" badge.
- **History** (Develop, kaliwa): bawat hakbang ng edit ay may pangalan (hal. "Exposure +0.50"). I-click para bumalik. Naka-sync ito sa ⌘Z / ⇧⌘Z.
- **Snapshots** (Develop, kaliwa): + para i-save ang kasalukuyang edit sa isang pangalan. Hover = preview, click = apply.
- **Before / After** (**Y** o mga button sa toolbar): Side by Side, o Split na may divider na nadi-drag. Sabay ang zoom.
- **Export presets** (Presets menu sa Export) at **Watermark**: text (hal. "© Malayte") o PNG logo, may Position, Size, Opacity, at Margin.

**Mula sa v0.9.0**
- **Zoom:** unti-unti na (mga 9% kada ikot ng scroll wheel), at dumudulas ang pag-zoom sa halip na tumalon.
- **Profiles:** Darkroom Color, Standard, Vivid, Portrait, Landscape, Neutral, Monochrome (at Camera Neutral para sa RAW), may **Amount** 0–200. Ito ang sariling looks ng Darkroom na kahawig ng karaniwang camera profiles, hindi kopya ng profiles ng Adobe o ng camera brand.
- **LUT profiles:** Profile → Import LUT Profile (.cube). Puwedeng gamitin sa kahit anong photo, may Amount din.
- **Presets:** may **Amount** (0–200%) sa itaas ng listahan. **Hover** sa preset = preview sa photo. Kapag binago ang Amount pagkatapos mag-apply, naa-update ang huling preset.
- **Metadata (Library → Metadata):** Title, Caption, Creator, Copyright, Keywords. Puwedeng sabay-sabay sa maraming napiling photo. Kasama ito sa export (IPTC/XMP).
- **Search** sa Library Filter: file name, title, caption, creator, keywords.
- **AI Cull…** (Library Filter bar): sinusuri ng Mac (on-device) ang sharpness, nakapikit na mata, screenshots, aesthetic score (macOS 15+), at magkakahawig na shots. Puwedeng i-Pick ang pinakamaganda sa bawat grupo, i-Reject ang malabo o nakapikit, at lagyan ng stars. May ✨ badge sa thumbnails, at may **Best first** na sort.

**Mula sa v0.8.1**
- Ayos: hindi na nagka-crash kapag nagbubura ng mask (o ng Point Color swatch), pati pagkatapos ng undo.
- **Luminance Range:** may eyedropper na (Pick a Tone). Bubukas ito agad kapag gumawa ka ng Luminance Range mask.
- **Magnifier** habang nakatutok ang kahit anong picker (WB, Color Mixer, Point Color, mask Color/Luminance Range): pinalaking pixels sa paligid ng cursor, kasama ang R/G/B %.
- **Scroll wheel = zoom** sa pinupuntahan ng cursor (Loupe at Develop). Sa trackpad: two-finger scroll = pan, at ⌘ o ⌥ + scroll = zoom.
- **Naka-close na ang mga panel** sa simula (maliban sa Histogram, Navigator, Folders, at Presets). Naaalala pa rin kung alin ang binuksan mo.

**Mula sa v0.8.0: Masking (local adjustments)**
- Buksan sa ◌ button sa ilalim ng histogram, **⇧W**, o Photo → Masking.
- **Create New Mask:** Subject, Background (AI ng macOS), Brush (**K**), Linear Gradient (**M**), Radial Gradient (**⇧M**), Luminance Range, Color Range.
- Pagsamahin ang mga bahagi ng mask gamit ang **Add / Subtract / Intersect** (hal. Subject − Brush).
- **Brush:** Size, Feather, Flow, Erase (o hawakan ang **⌥ Option** para mag-erase).
- **Linear:** i-drag sa photo, buo ang epekto sa simula at wala na sa dulo. I-drag ang mga tuldok para ayusin.
- **Radial:** i-drag para gumawa ng ellipse. Galawin ang gitna o ang gilid; may Feather, Angle, at Invert.
- **Adjustments per mask:** Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Saturation, Sharpness, at Color (Hue + Amount).
- Pula ang overlay ng napiling mask (**O** para i-on/off). Right-click ang mask para i-Duplicate o i-Delete. **Esc** para isara.
- Nakadikit ang masks sa photo kahit baguhin ang crop. Puwedeng kopyahin sa ibang photo (Copy Settings → Masks). Ang Subject ay ginagawa ulit para sa bawat photo.

**Mula sa v0.7.1 (calibration sa Lightroom, Teal Film preset)**
- Mas malakas na **Calibration Hue** (×4) at **HSL Hue** (×2), mas mahinang Calibration Saturation, mas malakas na **Color Grading** (×1.75) na umaabot na hanggang sa pinakamadilim na shadows.
- Hindi na sobrang tumitingkad ang matitingkad na kulay (hal. pula) kapag tinaasan ang Contrast.
- Batay sa isang pares (Lightroom vs Darkroom): Oklab color error 0.022 → 0.015.

**Mula sa v0.7.0**
- **Bagong sliders** (gaya ng Lightroom): manipis na track na may tatsulok na knob. **Double-click** sa pangalan o sa slider = reset. I-click ang numero para mag-type ng value. Hawakan ang **⌥ Option** habang nagda-drag para sa pinong adjustment.
- **WB eyedropper** (W o ang eyedropper sa tabi ng WB): i-click ang bagay na grey o puti sa photo. May WB menu: As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash (RAW).
- **Auto** tone (⌘U), Auto White Balance (⇧⌘U).
- **Point Color** panel: eyedropper para pumili ng kulay sa photo (hanggang 4), tapos Hue/Sat/Lum Shift at Range.
- **Color Mixer targeted tool** (◎): i-drag pataas/pababa sa kulay sa photo.
- **Treatment: Color / Black & White** (V) na may **B&W Mix** per kulay.
- **Tone Curve → Region** (parametric): Highlights, Lights, Darks, Shadows + splits.
- **Calibration** panel: Red, Green, Blue Primary (Hue, Saturation).
- **Clipping warning** (J): pula = sunog na highlights, asul = itim na shadows.
- Preset import: kasama na ang Calibration, B&W mix, Region curve, at Monochrome profiles. Kapag in-import ulit ang pack, napapalitan ang presets na pareho ang pangalan.

**Mula sa v0.6.0**
- **Zoom levels**: Fit, 25%, 50%, 100%, 200%, 400% (menu sa toolbar, o FIT/50%/100%/200% sa Navigator). **I-drag ang photo** para i-pan, o two-finger scroll sa trackpad. **Pinch** para mag-zoom. I-click ang photo: zoom sa pinindot na bahagi; i-click ulit: balik sa Fit. **Z** = Fit ↔ huling zoom level. Gumagana sa Loupe at Develop.
- **Import Presets** (↓ sa Presets panel, o Photo → Import Presets…): `.xmp`, `.lrtemplate`, `.dng` presets, at `.zip` packs. Ang hindi pa kaya (Masks, Healing, Calibration, Transform, Parametric curve) ay nilalaktawan at sinasabi sa iyo.
- Presets na may White Balance: Kelvin = para sa RAW lang, ang ±100 = para sa JPEG lang (gaya ng Lightroom).
- **Detail** panel: Sharpening, Noise Reduction (Luminance, Color). Sa RAW, ginagawa ito ng macOS RAW decoder (default Sharpening 40, Color 25).
- **Lens Corrections**: Enable Profile Corrections (RAW, kung may lens data ang macOS).
- **Presence**: **Texture**, **Clarity**, **Dehaze** (nasa Basic panel, gaya ng Lightroom).
- **Effects** panel: Post-Crop Vignetting (Amount, Midpoint, Roundness, Feather, Highlights) at **Grain** (Amount, Size, Roughness).
- Bagong Copy/Paste at preset groups: Detail, Effects.

**Mula sa v0.5.0: Lightroom Classic-style na UI**
- Itaas: pangalan ng app + module picker **Library | Develop**
- Kaliwa: **Navigator**, **Folders** (Library) o **Presets** (Develop), Import…/Export… o Copy…/Paste
- Kanan: **Histogram** (may ISO / mm / f / shutter), **Metadata** (Library), o mga Develop panel na nabubuksan/naisasara: Basic, Tone Curve, Color Mixer, Color Grading
- Gitna: **Library Filter** bar sa ibabaw ng grid, **toolbar** sa ilalim (view mode, flags, stars, zoom, thumbnail size)
- Ibaba: **Filmstrip** sa lahat ng module, may info line (folder · bilang ng photos · napili · file name)
- **Tab** = itago/ipakita ang side panels, **⇧Tab** = itago lahat, **F** = full screen
- Kulay-abong panels at maliit na text gaya ng Lightroom Classic; naaalala kung aling panel ang bukas

**Mula sa v0.4.0:**
- **Crop & Straighten** (R): aspect ratios (Original, Free, 1:1, 4:5, 5:7, 2:3, 16:9, portrait/landscape), Straighten ±45° (0.1°), Rotate Left/Right, rule of thirds. Hindi lumalabas sa photo ang crop (walang bakanteng sulok).
- **Zoom** (Z o i-click ang photo): sa Loupe (pang-check ng focus) at sa Develop (full-resolution render).
- **Histogram** sa itaas ng Develop panel, may clipping indicator.
- **Tone Curve**: RGB, Red, Green, Blue point curves (smooth spline, gaya ng Lightroom).
- **Color Grading wheels**: Hue + Saturation sa wheel, may Luminance, Blending, Balance.
- **Presets + Copy/Paste**: piliin kung aling grupo (Profile, WB, Tone, Presence, Tone Curve, Color Mixer, Color Grading, Crop). ⇧⌘C / ⇧⌘V; gumagana sa maraming napiling photo sa Grid.

**Mula sa v0.3.1 (calibration sa Lightroom):**
- **Darkroom Color** profile para sa RAW (default): base look na itinugma sa Adobe Color ng Lightroom (tone + kulay). May **Camera Neutral** para sa orihinal na RAW rendering ng macOS (Develop → Profile).
- Mga slider na na-calibrate sa Lightroom: Contrast (pivot + nagpapatingkad ng kulay gaya ng LR), Shadows, Highlights.
- Temp na ipinapakita gaya ng Lightroom (50 K steps).
- Batay sa isang CR3 (indoor court): zero settings ΔE 0.040 → 0.031; Highlights −60 / Shadows +40 / Contrast +30 ΔE 0.046 → 0.033.

**Mula sa v0.3.0:**
- **Lightroom-style engine** (port ng LumaGrader, tumatakbo sa GPU): local Highlights/Shadows (guided filter, walang halo), Exposure na may highlight shoulder, Whites/Blacks zones, logistic Contrast, Vibrance na nagpoprotekta sa skin tones, Bradford white balance para sa JPEG
- **Color Mixer (HSL)**: 8 kulay × Hue/Saturation/Luminance
- **Color Grading**: Shadows/Midtones/Highlights/Global (Hue, Saturation, Luminance) + Blending, Balance
- **Export** (⇧⌘E): JPEG/TIFF 16-bit/PNG, quality, resize, custom name + number, alisin ang GPS, batch

**Mula sa v0.2.0:**
- **Library**: import folder, grid, loupe, stars, Pick/Reject flags, filters, auto-advance
- **Multi-select**: ⌘-click / ⇧-click / ⌘A, at sabay-sabay na rating at flags
- **RAW + JPEG stack**: isang thumbnail lang ("RAW+JPG") para sa parehong shot
- **Compare**: dalawang photo magkatabi (Select vs Candidate)
- **Develop**: totoong RAW decode (macOS), White Balance, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Vibrance, Saturation, before/after, undo. Non-destructive: naka-save ang edits sa catalog, at hindi ginagalaw ang file.
- **Totoong `.app`** na may icon (`scripts/make-app.sh`)

## Kailangan

- macOS 14 Sonoma o mas bago
- Xcode (libre sa Mac App Store)

## Paano patakbuhin

### A. Sa Xcode (habang dine-develop)
1. I-double-click ang `Package.swift`.
2. Piliin ang **My Mac**, at pindutin ang **⌘R**.
3. Kapag may error, pindutin ang **⌘5**, tapos i-screenshot o kopyahin ang mga pulang error.

### B. Bilang app sa Applications (pang-araw-araw)
Sa Terminal:
```bash
cd ~/Desktop/App\ Development/darkroom
./scripts/make-app.sh --install
```
- Gagawin nito ang `LumaGrader Photo Studio.app`, ilalagay sa `/Applications`, at bubuksan.
- Puwede mo na itong buksan mula sa Launchpad o Spotlight, at i-keep sa Dock.
- Kada update ng code, patakbuhin ulit ang command na iyan.
- Kung may error na "xcrun" o "swift not found": `sudo xcode-select -s /Applications/Xcode.app`, tapos ulitin.

### C. Installer para sa ibang Mac (DMG)
```bash
cd ~/Desktop/App\ Development/darkroom
bash ./scripts/make-dmg.sh
```
- Gagawa ng `dist/LumaGrader-Photo-Studio-<version>.dmg` (universal: Apple silicon + Intel) at ipapakita sa Finder. Ito ang ipapadala.
- Sa unang run, may tanong na "Terminal wants to control Finder": **OK** (para maayos ang window ng DMG).
- Kailangan ng macOS 14+ sa kabilang Mac. Hindi notarized (walang Apple Developer account), kaya sa unang bukas: **System Settings ▸ Privacy & Security ▸ Open Anyway**. Nasa "Read Me First.txt" sa loob ng DMG ang buong instructions.

## Keyboard

| Key | Gawa |
|---|---|
| G / E / C / D | Grid / Loupe / Compare / Develop |
| Space | Grid ↔ Loupe |
| Esc | Lumabas sa zoom/crop, tapos balik sa Grid |
| ← / → | Previous / next photo (sa Compare: palit ng Candidate) |
| 0–5 | Star rating |
| P / X / U | Pick / Reject / Unflag |
| ⌘-click, ⇧-click, ⌘A | Multi-select (Grid at filmstrip) · ⌘D Select None |
| \\ | Before / after (Develop) |
| ⌘Z / ⇧⌘Z | Undo / redo ng edit (Develop) |
| ⇧⌘R | Reset edits (lahat ng napili) |
| ⌘[ / ⌘] | Rotate left / right |
| Q | Healing (Delete = bura ng spot, [ ] = size) |
| R | Crop & Straighten (Return o R para matapos, Esc para lumabas) |
| Z | Fit ↔ zoom (huling level; Loupe at Develop) |
| W | WB eyedropper (Develop) |
| V | Black & White |
| J | Clipping warning |
| ⌘U / ⇧⌘U / ⌥⌘U | Auto Tone / Auto WB / pareho (lahat ng napili) |
| ⇧W | Masking panel |
| Y | Before/After: Side by Side → Split → Off |
| ⌘' | Create Virtual Copy |
| K / M / ⇧M | Bagong Brush / Linear / Radial mask |
| O | Mask overlay on/off |
| Drag / two-finger scroll / pinch | Pan at zoom kapag naka-zoom |
| ⇧⌘C / ⌥⌘C | Copy settings (pipili) / Copy All |
| ⇧⌘V / ⌥⌘V | Paste / Paste from Previous (lahat ng napili) |
| ⇧⌘S | Sync settings: active photo → iba pang napili |
| Tab / ⇧Tab | Itago ang side panels / itago lahat |
| F | Full screen |
| ⇧⌘I | Import folder |
| ⇧⌘E / ⌥⇧⌘E | Export… / Export with Previous (lahat ng napili) |

- **Multi-select**: ang P/X/U, 0–5, presets, paste, Auto, Reset, Rotate at Export ay para sa lahat ng napili (Grid o filmstrip). Ang mga slider sa Develop ay para lang sa active photo; gamitin ang Sync (⇧⌘S) para ikalat.
- **Develop**: i-double-click ang pangalan ng slider para i-reset. Ang **As Shot** ay ang white balance ng camera.
- **Options** (⚙︎ sa toolbar): Auto-advance, Stack RAW + JPEG.

## Saan naka-save

- **Catalog:** `~/Library/Application Support/Darkroom/Catalog.sqlite` (folders, ratings, flags, edits, metadata, AI Cull results)
- **Catalog backups:** `~/Library/Application Support/Darkroom/Backups` (o ang pinili mong folder; File ▸ Catalog Backup)
- **LUT profiles:** `~/Library/Application Support/Darkroom/Profiles` · **Subject masks:** `…/Darkroom/Masks`
- **Thumbnail cache:** `~/Library/Caches/Darkroom/Thumbnails` (puwedeng burahin anumang oras)
- Hindi ginagalaw, nililipat, o binabago ang photo files mo.
- May bagong photos sa folder? Right-click ang folder → **Synchronize Folder**.

## Structure

```
Package.swift
Resources/AppIcon.icns, AppIcon-1024.png, dmg-background(@2x).png, Read Me First.txt
scripts/make-app.sh              build (+ --install, --universal) ng LumaGrader Photo Studio.app
scripts/make-dmg.sh              installer: dist/LumaGrader-Photo-Studio-<version>.dmg
Sources/Darkroom/
├── Library/TetherWatcher.swift  hot-folder watcher (tethered capture); LibraryStore+Tether, Views/TetherViews
├── Support/FocusPeaking.swift   focus peaking + sharpest area (Focus Check)
├── Views/GuideView.swift + GuideContent.swift   Help ▸ DarkLab Guide (Features, Mac Security, About)
├── Print/                       PrintSettings (layout), PrintProfiles (ICC), PrintRenderer, PrintModel + PrintPageView
├── DarkroomApp.swift            app entry, menus (Undo/Redo, Photo)
├── Models/                      Photo, Folder, Flag, DevelopSettings
├── Catalog/Catalog.swift        SQLite catalog (migrations via user_version; v2 = develop)
├── Library/                     FolderScanner, ImageLoader, ThumbnailDiskCache, LibraryStore, CullingAnalyzer (AI Cull)
├── Develop/
│   ├── DevelopKernel.swift      LumaGrader develop shader (Metal, GPU)
│   ├── LumaEngine.swift         CPU side: exposure shoulder, white balance, grading
│   ├── GuidedFilter.swift       edge-aware local brightness (Highlights/Shadows)
│   ├── DevelopRenderer.swift    decode (CIRAWFilter / CIImage) → kernel
│   ├── DevelopSession.swift     live editing: background render, autosave, undo
│   ├── PresetImporter.swift     .xmp / .lrtemplate / .dng / .zip presets → Darkroom presets
│   ├── MaskRenderer.swift       masks: gradients, brush, Select Subject (Vision), local adjustments
│   ├── ProfileRenderer.swift    Darkroom looks + LUT profiles (.cube)
│   ├── DevelopSession+Masks.swift  mask editing (drawing on the photo)
│   ├── DevelopSession+Healing.swift  Healing tool (spots, auto source)
│   ├── RetouchRenderer.swift    Heal/Clone, Denoise, Lens Blur (Metal) + iPhone depth maps
│   ├── AutoAdjust.swift         batch Auto Tone / WB
│   └── ToneCurve.swift          fallback tone curve (kung pumalya ang GPU engine)
├── Export/Exporter.swift        render + save (metadata, naming)
├── Support/                     folder picker, keyboard shortcuts
└── Views/                       panels, grid, loupe, compare, develop, ZoomPanView (zoom + pan)
```

## Alam na limitasyon

- RAW support = kung ano ang suportado ng macOS mo. Ang bagong camera ay suportado kapag na-update ang macOS.
- Ang tone engine ay naka-calibrate sa LumaGrader (isang Lightroom comparison). Para mas tumugma: parehong photo + parehong sliders sa Lightroom at Darkroom, ipadala kay Claude.
- Ang GPU engine ay kino-compile ng macOS pagbukas ng app. Kapag pumalya, gagamit ito ng basic engine at may orange na mensahe sa ilalim ng Develop panel. Ipadala ang mensaheng iyon kay Claude.
- Ang Compare view ay walang zoom pa. Ang Grain at Vignette ay hindi kapareho ng Lightroom pixel-for-pixel; ang Sharpening/NR ng JPEG ay mas simple kaysa sa RAW. Ang presets ay naka-save sa catalog (isang Mac lang).
- Sa RAW+JPEG stack, sa RAW lang napupunta ang ratings at flags.
- Ang undo ay para sa Develop edits lang, hindi pa sa ratings at flags. Ang batch edits sa Grid ay walang undo (gamitin ang History sa Develop ng bawat photo, o Reset).
- **Healing** ay bilog na spots lang (wala pang brush-shaped na heal). Ang auto source ay base sa kulay sa paligid; i-drag kung hindi tama.
- **Denoise** ay sariling GPU filter ni Darkroom (walang public AI denoise ang macOS); mabuti sa ISO 3200–12800 pero hindi kasing-linis ng AI Denoise ng Lightroom. Mas mabigat ito sa export.
- **Lens Blur** ay walang AI depth para sa ordinaryong photos: subject vs background lang (Select Subject). Ang iPhone Portrait (HEIC/JPEG na may depth) ang may tunay na depth.
- Ang loupe at grid ng **hindi pa na-edit** na RAW ay galing sa embedded preview (mabilis). Kapag na-edit, totoong RAW decode na ang gamit.

## Roadmap

1. ~~Library~~ ✅
2. ~~Develop (basic)~~ ✅
3. ~~Lightroom-style engine, Export, HSL, Color Grading~~ ✅
4. ~~Crop + Straighten, Zoom 100%, Histogram, Tone Curve, Color wheels, Presets + Copy/Paste~~ ✅
5. ~~Lightroom Classic-style UI~~ ✅
6. ~~Detail + Effects, zoom levels + pan, preset import~~ ✅
7. ~~WB picker, Point Color, B&W, Region curve, Calibration, Auto~~ ✅
8. ~~Masks~~ ✅
9. ~~Library tools, Collections, Virtual Copies, History, Snapshots, Export presets~~ ✅
10. ~~Healing, Denoise, Lens Blur, right-click menu, batch shortcuts~~ ✅
11. Susunod: **HDR / Panorama merge, Face tagging, Map (GPS)**
