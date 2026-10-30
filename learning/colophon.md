---
title: Colophon
nav_order: 150
---

# Colophon

NerfLearning was written for one reader: an experienced Perl programmer, fluent in
Rust, learning Swift and SwiftUI by way of an app of their own. Every example is real
code from NerfJournal, and every comparison is to a language that reader already
knew. That's why it's of questionable value to anybody else, and also the point.

The text was written by Claude, across several model generations, between March and
October 2026. A syllabus came first. After that, each unit was written only when the
reader was ready for it, then read and questioned. Questions that came up while
reading were answered on the spot and later folded back into the unit they came from,
so the text gained what the reader found missing, most often a definition that had
been assumed or a framework that needed placing in context.

The app kept changing underneath the book. Instead of chasing it continuously, the
text was reconciled with the code at intervals, each one a merge of the app's main
branch into this branch that marks an **edition**. There were nine. The last one
followed NerfJournal's move to a JMAP backend, a change too big to patch into the
earlier units. They were left as written and preserved as the git tag
`edition-local-sqlite`, and the [coda](coda) maps where they no longer match the code.

By the numbers: thirteen units and a coda, about 45,000 words, and about ninety commits.

The site is built with [Jekyll](https://jekyllrb.com/) and the
[Just the Docs](https://just-the-docs.com/) theme, and published by GitHub Pages from
the `swift-learning` branch of
[NerfJournal](https://github.com/rjbs/NerfJournal). Its icon is NerfJournal's.
