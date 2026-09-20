// Renders Aliob launcher icons + in-app logo PNGs from the canonical SVG sources.
// Stand-in for `dart run flutter_launcher_icons` in environments without the
// Flutter SDK (same sources, same sizes). Requires: npm i sharp (any dir).
// Usage: node tool/icons/render.js <repoRoot>
const { createRequire } = require('module');
const req = createRequire('/tmp/rebrand-tools/package.json');
const sharp = req('sharp');
const fs = require('fs');
const path = require('path');

const REPO = process.argv[2] || process.cwd();
const ROUNDED_SVG = path.join(REPO, 'tool/icons/aliob_icon_rounded.svg');
const SQUARE_SVG = path.join(REPO, 'tool/icons/aliob_icon_square.svg');

async function masterBuffer(svgPath) {
  // Rasterize the 512x512 SVG at 2x (1024px) for high-quality downscales.
  return sharp(fs.readFileSync(svgPath), { density: 144 })
    .resize(1024, 1024)
    .png()
    .toBuffer();
}

function assert(cond, msg) {
  if (!cond) { console.error('ASSERT FAIL: ' + msg); process.exitCode = 1; }
  else console.log('ok: ' + msg);
}

async function pixel(buf, x, y) {
  const raw = await sharp(buf).extract({ left: x, top: y, width: 1, height: 1 }).raw().toBuffer();
  return Array.from(raw);
}

async function writePng(master, size, outPath, flatten) {
  let p = sharp(master).resize(size, size);
  if (flatten) p = p.flatten({ background: '#05462F' });
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  await p.png().toFile(outPath);
  console.log(`wrote ${outPath} (${size}x${size}${flatten ? ', flattened' : ''})`);
}

(async () => {
  const rounded = await masterBuffer(ROUNDED_SVG);
  const square = await masterBuffer(SQUARE_SVG);

  // ---- Pixel assertions on the rounded master (1024) ----
  const corner = await pixel(rounded, 8, 8);
  assert(corner[3] < 40, `rounded corner transparent (alpha=${corner[3]})`);
  const topC = await pixel(rounded, 512, 60);
  assert(topC[1] > 80 && topC[1] > topC[2], `gradient green at top-center rgb=${topC.slice(0, 3)}`);
  // White left half of droplet, clear of the black "A" stroke cutout:
  // pre-transform (230,340) -> (233.6,307.6) @512 -> (467,615) @1024.
  const whiteHalf = await pixel(rounded, 467, 615);
  assert(whiteHalf[0] > 230 && whiteHalf[1] > 230 && whiteHalf[2] > 230, `white droplet half rgb=${whiteHalf.slice(0, 3)}`);
  // Light-green right half: pre (312,300) -> (282,273) @512 -> (564,546) @1024.
  const lightHalf = await pixel(rounded, 564, 546);
  assert(lightHalf[0] > 190 && lightHalf[0] < 235 && lightHalf[1] > 230, `light-green droplet half rgb=${lightHalf.slice(0, 3)}`);
  // The black stroke cutout masks back to the gradient (green visible).
  const cutout = await pixel(rounded, 460, 443);
  assert(cutout[1] > 100 && cutout[1] > cutout[2] && cutout[1] > cutout[0], `stroke cutout shows gradient rgb=${cutout.slice(0, 3)}`);
  // Gold dot: pre (256,276) -> (256,252.6) @512 -> (512,505) @1024.
  const gold = await pixel(rounded, 512, 505);
  assert(gold[0] > 200 && gold[1] > 130 && gold[1] < 200 && gold[2] < 90, `gold dot rgb=${gold.slice(0, 3)}`);

  // ---- Pixel assertions on the square master (1024): fully opaque ----
  const sqCorner = await pixel(square, 2, 2);
  assert(sqCorner[3] === 255, `square icon fully opaque (alpha=${sqCorner[3]})`);
  const sqTop = await pixel(square, 512, 60);
  assert(sqTop[1] > 80, `square gradient green rgb=${sqTop.slice(0, 3)}`);

  // ---- Outputs ----
  await writePng(rounded, 512, path.join(REPO, 'assets/images/aliob_logo_mark.png'), false);
  await writePng(rounded, 1024, path.join(REPO, 'tool/icons/aliob_icon_android.png'), false);
  await writePng(square, 1024, path.join(REPO, 'tool/icons/aliob_icon_ios.png'), true);

  // Android mipmaps (rounded, transparent corners).
  const android = [
    ['mipmap-mdpi', 48], ['mipmap-hdpi', 72], ['mipmap-xhdpi', 96],
    ['mipmap-xxhdpi', 144], ['mipmap-xxxhdpi', 192],
  ];
  for (const [dir, size] of android) {
    await writePng(rounded, size, path.join(REPO, `android/app/src/main/res/${dir}/ic_launcher.png`), false);
  }

  // iOS AppIcon.appiconset (full-bleed, flattened) — exact filenames from Contents.json.
  const ios = [
    ['Icon-App-20x20@1x.png', 20], ['Icon-App-20x20@2x.png', 40], ['Icon-App-20x20@3x.png', 60],
    ['Icon-App-29x29@1x.png', 29], ['Icon-App-29x29@2x.png', 58], ['Icon-App-29x29@3x.png', 87],
    ['Icon-App-40x40@1x.png', 40], ['Icon-App-40x40@2x.png', 80], ['Icon-App-40x40@3x.png', 120],
    ['Icon-App-60x60@2x.png', 120], ['Icon-App-60x60@3x.png', 180],
    ['Icon-App-76x76@1x.png', 76], ['Icon-App-76x76@2x.png', 152],
    ['Icon-App-83.5x83.5@2x.png', 167],
    ['Icon-App-1024x1024@1x.png', 1024],
  ];
  for (const [name, size] of ios) {
    await writePng(square, size, path.join(REPO, `ios/Runner/Assets.xcassets/AppIcon.appiconset/${name}`), true);
  }

  console.log(process.exitCode ? 'DONE WITH ASSERT FAILURES' : 'ALL RENDERS + ASSERTS PASSED');
})().catch((e) => { console.error(e); process.exit(1); });
