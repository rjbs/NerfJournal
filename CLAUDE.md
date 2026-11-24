# NerfJournal

## NerfLearning

The learning curriculum in `learning/` is a sub-project called **NerfLearning**.
The user may refer to it by that name.

The site is built by Zensical from `learning/mkdocs.yml`: `learning/build.sh`
builds it in Docker, and `learning/build.sh serve` previews it.  The theme
settings there, and the rules in `learning/docs/extra.css`, are kept the same
as those of the Jinx manual (`../Jinx/doc/manual`) and the Go booklet in gizmo
(`../gizmo/learning`, on its `go-learning` branch).

The Markdown is Python-Markdown's, which is stricter than most: a list needs a
blank line before it, and a second paragraph or a code block inside a list
item must be indented four spaces.

When writing unit content:

- The reader knows Perl and Rust well. Compare Swift to Rust when it is more
  apt than a Perl comparison; use whichever language makes the concept clearest.
- When mentioning a Swift standard library type, protocol, or language feature
  for the first time, link to its official documentation on
  `developer.apple.com` if a stable URL exists.
