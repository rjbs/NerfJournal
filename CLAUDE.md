# NerfJournal

## NerfLearning

The learning curriculum in `doc/web/docs/learning/` is a sub-project called
**NerfLearning**.  The user may refer to it by that name.  It is one section
of NerfJournal's site.

The site is built by Zensical from `doc/web/mkdocs.yml`: `doc/web/build.sh`
builds it in Docker, and `doc/web/build.sh serve` previews it.  The theme
settings there, and the rules in `doc/web/docs/extra.css`, are kept the same
as those of the Jinx manual (`../Jinx/doc/manual`) and gizmo's site
(`../gizmo/doc/web`), except where `mkdocs.yml` says otherwise.

The Markdown is Python-Markdown's, which is stricter than most: a list needs a
blank line before it, and a second paragraph or a code block inside a list
item must be indented four spaces.

When writing unit content:

- The reader knows Perl and Rust well. Compare Swift to Rust when it is more
  apt than a Perl comparison; use whichever language makes the concept clearest.
- When mentioning a Swift standard library type, protocol, or language feature
  for the first time, link to its official documentation on
  `developer.apple.com` if a stable URL exists.
- Headings are in sentence case, as are titles and menu entries.  A proper
  noun keeps its capital, and the word after a colon does not get one.
- American spelling ("color", "canceled"), and the serial comma: "Snap,
  Crackle, and Pop".
