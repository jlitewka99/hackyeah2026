---
name: AiControl
description: A restrained private workspace for governed AI interactions.
colors:
  surface: "#ffffff"
  surface-subtle: "#f8f9fb"
  surface-hover: "#eff0f3"
  ink: "#18191d"
  muted: "#62646e"
  line: "#e4e5e9"
  action: "#23242a"
  action-ink: "#ffffff"
  focus: "#5265cf"
  danger: "#b42335"
  danger-bg: "#fff2f3"
  success: "#216344"
  success-bg: "#eef8f2"
  surface-dark: "#18191d"
  surface-subtle-dark: "#141519"
  surface-hover-dark: "#25262c"
  ink-dark: "#f2f3f5"
  muted-dark: "#a4a6b1"
  line-dark: "#303138"
  action-dark: "#f2f3f5"
  action-ink-dark: "#18191d"
  focus-dark: "#a0adff"
  danger-dark: "#ff9da8"
  danger-bg-dark: "#351d24"
  success-dark: "#91d7b2"
  success-bg-dark: "#183125"
typography:
  headline:
    fontFamily: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "1.75rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-0.025em"
  title:
    fontFamily: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "1.0625rem"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: "-0.015em"
  body:
    fontFamily: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.6
  control:
    fontFamily: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "0.875rem"
    fontWeight: 550
    lineHeight: 1.4
  label:
    fontFamily: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "0.8125rem"
    fontWeight: 550
    lineHeight: 1.6
  brand:
    fontFamily: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "0.9375rem"
    fontWeight: 650
    lineHeight: 1.6
    letterSpacing: "-0.02em"
rounded:
  control: "0.5rem"
  appearance-option: "0.3125rem"
  notice: "0.75rem"
spacing:
  compact: "0.5rem"
  control-inset: "0.625rem"
  close: "0.75rem"
  base: "1rem"
  comfortable: "1.5rem"
  section: "2rem"
  spacious: "3rem"
components:
  button-primary:
    backgroundColor: "{colors.action}"
    textColor: "{colors.action-ink}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "0.625rem 1rem"
  button-primary-dark:
    backgroundColor: "{colors.action-dark}"
    textColor: "{colors.action-ink-dark}"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "0.625rem 1rem"
  button-secondary-hover:
    backgroundColor: "{colors.surface-hover}"
  input-text:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0.625rem 0.75rem"
    width: "100%"
  input-readonly:
    backgroundColor: "{colors.surface-subtle}"
    textColor: "{colors.muted}"
  checkbox:
    width: "1rem"
    height: "1rem"
  navigation-link:
    textColor: "{colors.muted}"
    rounded: "{rounded.control}"
    padding: "0.5rem 0.625rem"
  navigation-link-current:
    backgroundColor: "{colors.surface-hover}"
    textColor: "{colors.ink}"
  appearance-option:
    textColor: "{colors.muted}"
    rounded: "{rounded.appearance-option}"
    width: "1.875rem"
    height: "1.75rem"
  appearance-option-selected:
    backgroundColor: "{colors.surface-hover}"
    textColor: "{colors.ink}"
  text-link:
    textColor: "{colors.ink}"
  notice-info:
    backgroundColor: "{colors.success-bg}"
    textColor: "{colors.success}"
    rounded: "{rounded.notice}"
    padding: "1rem"
  notice-error:
    backgroundColor: "{colors.danger-bg}"
    textColor: "{colors.danger}"
    rounded: "{rounded.notice}"
    padding: "1rem"
  workspace-empty:
    textColor: "{colors.muted}"
---

# Design System: AiControl

## Overview

**Creative North Star: "The Private Workspace"**

AiControl uses the restrained product-interface character established by the user-pinned Linear and Vercel references: neutral surfaces, compact system typography, small rounded controls, and quiet dividing rules. Its material is the working interface itself. The current implementation covers authentication, recovery, account settings, and the organizer workspace; it does not establish a visual system for reporting or policy tools that have not been built.

The interface is spacious around tasks and compact within controls. Identity, available actions, and feedback carry the hierarchy. Light and dark appearances preserve the same geometry, and appearance changes happen immediately without remounting forms. English copy and consistent technical terminology are durable product constraints. The implementation uses bundled icons and CSS rather than raster imagery.

### Design references

**Linear and Vercel are the user-selected references for AiControl's interface.** Use [Vercel's Geist introduction](https://vercel.com/geist/introduction) and [Linear's brand materials](https://linear.app/brand) as the visual reference points. Apply their direction through minimalist composition, precise typography, subtle borders, and consistent hover, focus, loading, disabled, error, and success states.

Keep this direction consistent across authentication, account settings, navigation, and future panels. Express it through the existing system font, neutral light and dark surfaces, spacing, and semantic state colors documented here.

**Key Characteristics:**

- Neutral light and dark surfaces with semantic feedback colors.
- A single system sans family with a compact, sentence-case hierarchy.
- Flat task regions, restrained rules, and small rounded controls.
- Immediate system, light, and dark appearance selection.
- Responsive navigation with visible account identity.

## Colors

The palette combines neutral action contrast with explicit focus, error, and success states; it has no decorative secondary or tertiary accent.

### Primary

- **Graphite Action / Pale Action:** `action` and `action-dark` fill the main submit button. `action-ink` and `action-ink-dark` supply its contrasting text. The checkbox uses the same action color.
- **Focus Indigo / Light Focus Indigo:** `focus` and `focus-dark` mark keyboard focus, input carets, and selected text. They are interaction colors rather than a general surface decoration.
- **Error Red / Light Error Red:** `danger` and `danger-dark` identify invalid field borders, error text, and error notices. Their corresponding `danger-bg` values tint the notice surface.
- **Success Green / Light Success Green:** `success` and `success-dark` identify informational or successful flash feedback. Their corresponding `success-bg` values tint the notice surface.

### Neutral

- **Workspace Surface:** `surface` is the page and input background; `surface-dark` is its dark counterpart.
- **Rail Surface:** `surface-subtle` and `surface-subtle-dark` differentiate the desktop navigation rail and readonly fields.
- **Hover Surface:** `surface-hover` and `surface-hover-dark` mark hovered secondary buttons and hovered or selected navigation and appearance options.
- **Primary Ink:** `ink` and `ink-dark` carry headings, ordinary text, labels, and links.
- **Supporting Ink:** `muted` and `muted-dark` carry descriptions, footer text, account context, and idle navigation.
- **Quiet Rule:** `line` and `line-dark` outline controls and separate task regions.

### Named Rules

**The Semantic State Rule.** Use focus, danger, and success colors for the interaction or feedback state they identify; preserve neutral surfaces for ordinary workspace content.

The frontmatter records each light value and its dark counterpart. CSS exposes the active values through semantic custom properties with the same names, without the `-dark` suffix. The sidecar's synthesized tonal ramps are swatch-preview metadata, not additional application theme tokens.

## Typography

**Display and Body Font:** The system sans stack in the frontmatter; there is no separate display or mono family in the implemented surfaces.

**Character:** Compact, legible, and familiar. Modest weight changes and slightly tightened heading tracking create hierarchy without oversized display type or decorative labels.

### Hierarchy

- **Headline:** Page titles use the headline token, balanced wrapping, and the same size on desktop and mobile.
- **Title:** Settings subsection headings and the organizer empty-state heading use the title token.
- **Body:** Main explanatory copy uses the body token. Workspace page descriptions have a maximum line length of 65 characters (`65ch`); the empty-state text region is capped at 32rem.
- **Control:** Buttons use the control token. Inputs and navigation use the same font size; inputs inherit normal weight, and the active navigation item uses the control weight. Smaller supporting settings copy and inline task links use 0.875rem with 1.25rem line height.
- **Label:** Field and checkbox labels use the label token. Authentication footers, account identity, and field errors use the same size with normal weight.
- **Brand:** The wordmark uses the brand token beside a bundled shield-check icon.

### Named Rules

**The Single Family Rule.** Keep headings, forms, navigation, and identity in the same system sans family; use the existing compact type roles to establish hierarchy.

## Layout

Authentication uses an 80px header with 32px horizontal padding and a centered container capped at 25rem. That cap includes 1rem of padding on each side: at the default 16px root size the wrapper is 400px and the usable form width is 368px. Its top padding is `clamp(2rem, 10vh, 7rem)`, with 4rem below the task. Description-to-form spacing is 2rem; fields have 1.125rem of bottom spacing. The remember-me and recovery row can wrap and keeps a 0.75rem gap.

The authenticated shell has a 14.5rem (232px) desktop rail, an independent flexible main region, and a minimum height of `100dvh`. The rail has a viewport height of `100dvh`, stays at the top of the screen while the main region scrolls, and scrolls independently when its own content exceeds the viewport. Its children retain their natural heights. It uses 1.5rem vertical and 1rem horizontal padding. Main content uses 3rem vertical padding and `clamp(1.5rem, 5vw, 5rem)` horizontal padding. The inner content is capped at 56rem (896px). Account identity sits near the rail's bottom with 2rem padding below its divider; a long desktop email is visually truncated while its full text remains in the DOM and in the title attribute.

Settings regions use a ruled two-column grid with a `1fr : 1.2fr` proportion, a 3rem gap, and 2rem vertical padding. The organizer state is separated by a rule and open spacing rather than a dashboard card. Fixed flash feedback sits 1.25rem from the lower-right edge, is capped at 26rem, and reserves 2.5rem of total horizontal viewport space.

At viewport widths of 767px and below, the rail disappears and navigation, sign-out, identity, and appearance controls move into a visible header. Account email wraps anywhere when needed. The authentication header becomes 72px tall with 16px side padding, and the auth task starts after 2.5rem of top padding. Workspace main padding becomes 2rem by 1.25rem. Settings stack into one column with a 1.5rem gap. Appearance options expand to 2.75rem (44px) square; their compact desktop size is recorded in the frontmatter.

### Named Rules

**The Same Task Rule.** Preserve the same form fields, navigation destinations, account identity, and feedback when the layout stacks for mobile or appearance changes.

## Elevation & Depth

The working surfaces are flat. Tonal differences distinguish the rail, hover states, and readonly fields; 1px rules distinguish control boundaries and task sections. Authentication forms, settings regions, and the organizer state have no surface shadows. Fixed flash notices use a semantic tint and border instead of a drop shadow. The loading progress bar's vendor shadow is utility feedback, not a surface-elevation token.

### Named Rules

**The Flat Task Rule.** Use the existing tonal surfaces and rules to separate task regions before introducing any surface shadow.

State changes on anchors, buttons, and inputs transition background, border, and text colors over 180ms with `ease-out`. Flash show and hide helpers use 300ms `ease-out` and 200ms `ease-in` opacity/position transitions; the smaller-screen exit uses a vertical translation and the wider-screen transition uses scaling. The global reduced-motion query sets transition and animation duration to zero, and reconnect icons only spin when motion is permitted.

## Shapes

Controls, navigation targets, the appearance group, and the brand symbol share the control radius. Individual appearance options use the smaller appearance-option radius. Flash notices use the notice radius. Borders are thin (1px), while the global keyboard-focus outline is 2px with a 3px offset. Input focus uses its own 2px offset. Icons are 16px within buttons, navigation, appearance options, and the 28px brand symbol; flash and field-error icons are 20px, and the organizer-state icon is 32px. Icons are bundled Heroicons rendered through the shared icon component.

## Components

### Buttons

Compact, steady action targets. Primary and secondary buttons share a minimum height of 2.75rem (44px), the control type and radius, 0.625rem by 1rem padding, and a 0.5rem icon gap. Primary buttons use action and action-ink with a matching border; hover reduces opacity to 0.86. Secondary buttons use the workspace surface, primary ink, and quiet-rule border; hover uses the hover surface. Both receive the global visible-focus outline. Authentication submissions fill the available form width; settings actions size to their labels.

Submitting changes the button label to the task's present-tense status, including “Signing in…”, “Sending…”, “Saving…”, and “Restoring…”. Disabled buttons use a waiting cursor and 0.55 opacity. Native authentication and recovery submissions also set the form's `aria-busy` state, prevent a second submission, and show the bundled top progress bar immediately. Returning through the browser's page cache restores the original button and form state. LiveView-managed forms use LiveView submission feedback; LiveView navigation and loading events show the progress bar after a 300ms delay.

### Inputs / Fields

Clear labels above small rounded fields. Text, email, and password inputs use the workspace surface, primary ink, a quiet-rule border, 100% width, a 2.75rem minimum height, and 0.625rem by 0.75rem padding. Hover darkens the border to supporting ink. Focus changes the border to focus indigo and adds the input-focus outline. Placeholder text uses supporting ink; readonly fields use the rail surface and supporting ink.

The shared form-input component derives errors from used fields. Invalid text inputs set `aria-invalid="true"` and show a danger border; error copy below the field includes a bundled exclamation icon and `role="alert"`, with a 0.375rem top margin. The shipped implementation does not add an error-description association or a custom disabled-input treatment; do not infer either from this document.

### Checkbox

A native 1rem square checkbox uses action color and 0.5rem right spacing. An inline-flex label aligns it vertically with the label text. The sign-in row wraps with the recovery link at narrow widths; recovery confirmation uses the same checkbox pattern.

### Navigation

Quiet links with explicit selection. Each destination has a 16px icon, supporting-ink label, 0.625rem icon gap, a 2.5rem minimum height, and 0.5rem by 0.625rem padding. Hover and `aria-current="page"` use the hover surface and primary ink; the current destination also increases weight. The same destinations render in the desktop rail and mobile header. Underlined task links and sign-out links use primary ink with a quiet-rule underline that strengthens on hover and a 4px underline offset.

### Appearance Selector

An immediately responsive three-option group: system, light, and dark. A quiet-rule outline and 0.1875rem padding enclose the icon-only buttons, with a 0.125rem gap. Hover and `aria-pressed="true"` use the hover surface and primary ink. Each button has an accessible label and title, and the enclosing group is named “Appearance”.

Without an explicit preference, appearance follows the system color scheme. The application bundle resolves the choice on the root element, updates pressed states, and applies explicit light or dark choices under the localStorage key `phx:theme`. Choosing system removes that stored value. System changes update system-selected tabs; storage events synchronize open tabs, and LiveView navigation reapplies the selection. CSS supplies system-dark values before the bundle resolves a choice. Appearance selection changes no form fields or navigation state.

### Flash Notices

Semantic feedback in a fixed stack. Info notices use success ink, background, and border; error notices use danger ink, background, and border. Each has the notice radius, 1rem padding, a 0.75rem internal gap, and a 0.75rem gap above it. The stack has `aria-live="polite"`, and notices use `role="alert"`; a labeled close button dismisses the message. Connection feedback is hidden until needed, names the failure, and shows an optional reconnect icon. Notices use the same focus styling as other controls.

### Organizer Empty State

A ruled content region with a supporting-ink building icon, a compact heading, an explanatory paragraph, and a real account-settings link. Its top margin is 2.5rem and desktop top padding is 3.5rem, reduced to 2rem on mobile. The implementation describes unavailable organization work clearly instead of introducing inert controls or invented activity. This pattern is an empty state, not a general-purpose card.

### Keyboard Access

A focus-revealed skip link targets `main-content`. Headings label settings and organizer regions, inputs retain visible associated labels, current navigation uses `aria-current`, and appearance buttons use `aria-pressed`. Keep these semantics with the corresponding visual patterns.

## Do's and Don'ts

### Do:

- **Do** use semantic CSS properties so all surfaces respond to the active light or dark appearance.
- **Do** preserve visible focus, associated field labels, active navigation semantics, and task-specific loading feedback.
- **Do** keep task regions flat and use the existing type, spacing, and quiet-rule hierarchy.
- **Do** preserve 44px appearance targets on mobile and allow long account identity to wrap there.
- **Do** respect reduced motion and keep appearance switching immediate without resetting form values.
- **Do** make empty states explain current capabilities and provide an available next action.

### Don't:

- **Don't** substitute decorative accent colors for the focus, error, or success roles.
- **Don't** hide account identity or navigation when moving from the desktop rail to the mobile header.
- **Don't** remove the full desktop email text or title when visually truncating a long identity.
- **Don't** infer tables, charts, chips, dialogs, or reporting patterns from unbuilt workflows or unused starter helpers.
- **Don't** introduce a separate display typeface or decorative raster imagery into the documented interface without an approved system change.
