# 蕾姆 App 图标生成说明

生成方式：内置 image_gen（透明背景），未使用 CLI 或外部 API Key。

最终源图：`assets/branding/rem_logo.png`，RGBA PNG，1254 × 1254。
Android 多分辨率与自适应图标通过 `flutter_launcher_icons.yaml` 生成；页面 Logo 使用同一源图。
外形预览：`design/rem-logo-preview.html`；本地预览安装包：`build/branding-preview/daily-consume-rem-preview.apk`。

## 最终生成提示词

```text
Use case: logo-brand. Asset type: Android adaptive launcher icon foreground and tiny in-app avatar logo.
Create a single original, polished chibi anime portrait of Rem from Re:Zero, unmistakably recognizable, suitable for a minimalist personal diary app icon.
Appearance: light blue short bob haircut, long side bangs covering one eye, one large gentle blue eye clearly visible, the distinctive white frilled maid headband, a small pink flower hairpin with a black ribbon, minimal black-and-white maid collar. Cute calm slight smile, friendly and restful, small subtle blush. Head and only a little of the shoulders; no hands, no body below the upper shoulders, no weapons, no props.
Style: simplified clean 2D anime / crisp vector-friendly sticker artwork, bold smooth dark navy outline, large readable shapes, limited palette of soft blue, white, navy, and a tiny pink accent, very restrained cel shading. Avoid elaborate hair strands, tiny frills, fine sparkles or jewelry. Her face and hair should remain recognizable when displayed at 32 pixels.
Composition: square canvas, exactly one centered front-facing head-and-shoulders portrait, comfortably within about 80 percent of canvas width and height, balanced safe transparent margins on all sides, fully preserve headband and hairpin. The portrait silhouette can have a thin ivory outer sticker outline for contrast on a sage green launcher background. No framing tile or circle around the character.
Background: genuinely transparent alpha, not a checkerboard painted into the image. No gradients or environment.
No text, letters, numbers, watermark, signature, repeated characters, comparison layout, phone mockups, or extra objects. This must be a finished standalone usable icon foreground, not a sketch.
```

## 检查

- 源图透明通道范围为 0–255。
- Android launcher 图标生成成功，绿色自适应背景为 `#64765A`。
- Flutter 静态分析通过，`No issues found`。
- APK 构建成功，预览包已保存；本次没有发布 GitHub Release。
