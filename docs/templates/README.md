# SMS guide authoring

Build the dated offline guide and plain-text narration from the repository root:

```sh
python3 -m pip install Markdown
python3 scripts/build_sms_categorization_guide.py
```

The builder reads the reference Markdown, narration Markdown, both SVG diagrams, the captured synthetic-probe JSON and `sms-categorization-guide.html` in this directory. It writes the standalone HTML guide and the narration `.txt` file. It makes no network or application-runtime calls.

The reference's 18 numbered sections are the detailed source material. The narration has 20 chapters: the overview, the detailed diagram, then one chapter per reference section. Each chapter's `target` comment identifies its page anchor; `On screen` supplies the visual cue; text after `### Narration` becomes the spoken content. The text export excludes visual directions and Markdown links.

Change the template for layout or controls, and change the narration Markdown for spoken wording. Keep the original source-audit date and runtime limitations distinct from later changes to the learning interface. Browser speech is optional; the script and diagrams remain available without it.
