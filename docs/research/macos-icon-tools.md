# macOS app icon generation tools

Research date: 2026-09-11

## Conclusion

The strongest match is [`giginet/apple-icon-composer-skill`](https://github.com/giginet/apple-icon-composer-skill). Its `compose-app-icon` agent skill creates, edits, validates, and previews Apple Icon Composer `.icon` packages. The repository ships as a Claude Code plugin, a Codex plugin, or a standalone skill installed with `gh skill`.[^composer-readme]

This is the right tool when "generate a macOS icon" means "build the modern layered icon package that Xcode consumes." It is not an image model. It expects PNG or SVG artwork and packages those assets with an `icon.json` document. The skill handles Default, Dark, and tinted variants, validates asset references against a bundled JSON Schema, and can render a preview through Icon Composer's `ictool` when a suitable Xcode installation is present.[^composer-skill]

Apple's own tool is [Icon Composer](https://developer.apple.com/icon-composer/). Apple says it builds one layered Liquid Glass design for iPhone, iPad, Mac, and Apple Watch, supports multiple appearance modes, and produces a file that can be added directly to Xcode. The current download requires macOS Tahoe 26.4 or later.[^apple-composer]

## Recommended Codex setup

The plugin's only runtime dependency is `uv`; its Python project depends on `jsonschema`.[^composer-pyproject] The plugin manifest declares one skill and no MCP server or hook.[^composer-manifest]

```bash
# Only if uv is missing
brew install uv

# Add the repository marketplace and install its plugin
codex plugin marketplace add giginet/apple-icon-composer-skill
codex plugin add icon-composer@icon-composer
```

The second command follows the marketplace and plugin names declared by the repository. OpenAI's plugin documentation confirms `codex plugin marketplace add owner/repo` as the supported way to track a repository marketplace.[^openai-plugins] Start a new Codex session after installation so the skill is loaded.

A smaller installation that copies only the skill is also available through GitHub CLI 2.90.0 or later:[^composer-readme]

```bash
gh skill install giginet/apple-icon-composer-skill compose-app-icon \
  --agent codex --scope user
```

Typical use is conversational: ask Codex to create a `.icon` package from named PNG or SVG layers, edit a color or appearance variant, validate an existing package, or render a macOS preview. The underlying authoring command is:

```bash
uv run python create_icon.py \
  --output /path/to/App.icon \
  --icon /path/to/icon.json \
  --asset symbol.png=/path/to/symbol.png
```

The skill normally constructs that command and validates the result for the user.[^composer-skill]

## Important limitation

`compose-app-icon` is a third-party project, not an Apple tool. Its `icon.json` schema and `ictool` workflow come from the repository, while Apple's public Icon Composer page documents the GUI and Xcode integration but not this schema or CLI. Treat an actual Icon Composer render as the compatibility check after schema validation.

It also does not invent the visual artwork. A useful pipeline is:

1. Generate or draw separate 1024-by-1024 source layers.
2. Use `compose-app-icon` to build and validate the `.icon` package.
3. Open or render it with Apple's Icon Composer, inspect Default, Dark, and tinted modes, then add it to Xcode.

Codex's installed `imagegen` skill can produce raster source artwork, but it does not create `.icon`, `.icns`, or Xcode asset-catalog structures. Pairing `imagegen` with `compose-app-icon` covers both visual generation and Apple packaging.

## Other likely match

[`rshankras/claude-code-apple-skills`](https://github.com/rshankras/claude-code-apple-skills) contains an `app-icon-generator` skill. It programmatically draws flat icons with an AppKit/CoreGraphics Swift script, generates light, dark, and tinted variants, resizes macOS artwork with `sips`, writes `AppIcon.appiconset/Contents.json`, and prepares flat source layers for Icon Composer.[^app-icon-generator]

This candidate is more likely if the tool you saw promised to design a placeholder or populate an Xcode asset catalog. Its own documentation explicitly says it does not author the final layered `.icon` package. It hands that step to Icon Composer. The repository's documented installation targets Claude Code:

```text
/plugin marketplace add rshankras/claude-code-apple-skills
/plugin install apple-skills@indie-apple-stack
```

For Codex, the dedicated `giginet` plugin is the cleaner choice because its repository already includes a Codex marketplace and manifest.

## Native tools already on this Mac

Local checks on 2026-09-11 found:

- `/usr/bin/iconutil` is installed. It converts a classic `.iconset` directory to `.icns`, or converts `.icns` back to `.iconset`. It does not generate artwork.
- `uv 0.8.19` and GitHub CLI 2.100.0 are installed, so the skill's prerequisites are satisfied.
- `xcode-select -p` points to `/Library/Developer/CommandLineTools`, not full Xcode.
- `actool` and Icon Composer's `ictool` were not found. The skill can still perform portable JSON Schema validation, but cannot run its final Apple rendering check until full Xcode and Icon Composer are installed.

Classic `.icns` conversion remains available:

```bash
iconutil --convert icns --output AppIcon.icns AppIcon.iconset
iconutil --convert iconset AppIcon.icns
```

For a new macOS 26-or-later app, prefer Icon Composer's `.icon` workflow over treating `iconutil` as the generator.

## Sources

[^composer-readme]: Giginet, [Icon Composer Skill README](https://github.com/giginet/apple-icon-composer-skill/blob/eb6051e9853bccd68c2875fa032694107db8269e/README.md).
[^composer-skill]: Giginet, [`compose-app-icon` skill source](https://github.com/giginet/apple-icon-composer-skill/blob/eb6051e9853bccd68c2875fa032694107db8269e/plugins/icon-composer/skills/compose-app-icon/SKILL.md).
[^composer-pyproject]: Giginet, [bundled Python project](https://github.com/giginet/apple-icon-composer-skill/blob/eb6051e9853bccd68c2875fa032694107db8269e/plugins/icon-composer/skills/compose-app-icon/scripts/pyproject.toml).
[^composer-manifest]: Giginet, [Codex plugin manifest](https://github.com/giginet/apple-icon-composer-skill/blob/eb6051e9853bccd68c2875fa032694107db8269e/plugins/icon-composer/.codex-plugin/plugin.json).
[^apple-composer]: Apple, [Icon Composer](https://developer.apple.com/icon-composer/).
[^openai-plugins]: OpenAI, [Package your plugin](https://developers.openai.com/plugins/build/plugins#add-a-marketplace-from-the-cli).
[^app-icon-generator]: R. Shankras, [`app-icon-generator` skill source](https://github.com/rshankras/claude-code-apple-skills/blob/9ffb83138209057875698dd11c1720c657c47a92/skills/generators/app-icon-generator/SKILL.md).
