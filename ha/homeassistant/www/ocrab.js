// Loaded by frontend.extra_module_url, themes can only name a font family so
// the face itself is registered here
const ocrab = new FontFace("ocrab", "url(/local/fonts/ocrab.woff2)");
ocrab.load().then((face) => document.fonts.add(face));
