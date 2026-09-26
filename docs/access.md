# Who may do what

Whether someone may do something is answered by `Apiary.Access` and nowhere else. No code
outside it compares a membership's level. Roles will grow, and operators will reach the
organisations they manage; a rule written in one place grows there, where a comparison
repeated across the contexts and pages would be changed in some places and missed in
others.

## A new action goes into the module

Anything a person, an access key or a job can do that changes something, or that reads
something a role could one day be refused, is an **action**. A new one, or a new feature's
actions:

1. is added once to the action list in `Apiary.Access`, with the feature it belongs to
   (none: every instance has it) and a line saying what it is, which the module's
   documentation tabulates;
2. is given to the roles that may take it, in the module's role table;
3. gets its rows in `test/apiary/access_test.exs`: yes or no for every kind of actor that
   matters. The test fails for an action in the list without rows.

## The context function asks before it acts

Every context function that changes something calls `Apiary.Access.authorize/3` with its
action and the subject first, and returns what it answers:

- `{:error, :not_found}` for a feature that is off, or a subject of another organisation or
  workspace;
- `{:error, :forbidden}` for a role that does not allow the action.

This is the check that counts. `authorize/3` reads the membership again, so a scope loaded
earlier cannot act on a level that has changed since. A job and a contract endpoint reach
the change through the same function, so they are asked too.

## The page asks the same question

- A page shows a button, a link or a tab by `Apiary.Access.can?/3` with the same action as
  the function behind it, so the two cannot disagree. `can?/3` answers from the scope as
  loaded, with no database read, and is cheap on every render.
- A page that reads asks its read action on mount, `on_mount {ApiaryWeb.Access, action}`,
  after the path scope and the feature gate, and answers not found when refused.
