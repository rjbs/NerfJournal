Write the next unit of NerfLearning.

First, sync this branch with `main` by **merging** `main` into it — do not
rebase. `swift-learning` is a published "Editions" branch: each sync is a merge
commit that marks the edition boundary (the `main` commit this edition of the
text was reconciled against). Note the branch tip first (`git rev-parse HEAD`)
so you can review what the merge pulled in.

Review the changes `main` brought in with that merge (`git diff <old-tip>..HEAD`,
or the merge's second-parent diff). If changes to the project suggest that
`learning/SYLLABUS.md` should be updated for future chapters, make those changes
and commit it.

Then review the file `learning/questions.md`, which reflects questions from the
reader during the last unit.  Merge the material from the questions into the
unit they came from.  Remove the now-merged questions from the questions file.
Commit that.

Then write the next unit from the syllabus.  When doing so, reflect on the
question-and-answers content you just merged into the previous unit.  That
reflects the kind of thing that the reader felt was missing from the text.

Commit the new unit.
