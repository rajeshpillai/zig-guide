/**
 * The four tracks the guide divides into, and the sections in each, in order.
 *
 * This table is the section ordering. It used to be emergent: sections were
 * sorted by whichever of their chapters happened to carry the lowest `order`,
 * which meant the number line had to stay globally consistent across every
 * section at once. It had already run out. Language Basics owned 10 through 40
 * and the Standard Library started at 15, so there was no integer left to open
 * a section between them, and the cookbook had reached `92.7` and `92.9`
 * finding room for two recipes. Naming the order here instead leaves `order` to
 * do one job: sort chapters inside their own section, where the numbers only
 * ever have to agree with eight or ten neighbours.
 *
 * A track is a display and ordering concept, never a URL segment. Chapters stay
 * at `/orm/repo/`, not `/projects/orm/repo/`, so introducing this moved no page
 * and broke no link. It also means tracks need no index page of their own, and
 * `readingOrder()` emits no stop for one: the linear walk through the guide is
 * exactly what it was, and the pager gate that checks it needed no change.
 *
 * Why tracks exist at all: with one project the flat section list was fine. With
 * several, a reader following "next" off the end of Graphics lands in chapter
 * one of an ORM, and every link on the way resolves, so nothing fails. The
 * grouping is what tells them a project is a different kind of thing from a
 * topic tour before they are ten chapters into one.
 */
export interface Track {
  title: string;
  /** One line under the heading on the home page. */
  blurb: string;
  /** Section directories, in the order a reader meets them. */
  sections: string[];
}

export const TRACKS: Track[] = [
  {
    title: "Groundwork",
    blurb: "What the machine is doing, from zero. No C and no prior systems work assumed.",
    // First, and separate from Foundations, because it answers a different
    // question. Foundations teaches the language: what `*T` means and what the
    // compiler will not let you do with it. This teaches the machine the
    // language is describing: that an address is a number, that a type is an
    // agreement about how to read bytes, that a size is a choice with a cost.
    // A reader who already knows that skips the track entirely, which is why
    // it is a track and not a rewrite of Language Basics.
    sections: ["systems-from-scratch"],
  },
  {
    title: "Foundations",
    blurb: "The language and the library it ships with. Start here.",
    sections: ["getting-started", "language-basics", "standard-library", "data-structures"],
  },
  {
    title: "Systems",
    blurb: "Zig against the world outside the process: networks, builds, C, wasm, and pixels.",
    // The OS section first: a socket is a file descriptor, and Networking
    // opens by explaining what a handle is on its way to what an address is.
    // Networking next, and after Foundations rather than inside it: the
    // concurrency chapter needs `std.Io` and the protocol chapters lean on
    // the readers and writers taught in the Standard Library.
    sections: ["os", "networking", "build-system", "working-with-c", "webassembly", "graphics"],
  },
  {
    title: "Cookbook",
    blurb: "Task-shaped recipes, each a complete program CI compiled and ran.",
    sections: ["how-to"],
  },
  {
    title: "Projects",
    blurb: "One library at a time, designed in the open, one decision per chapter.",
    sections: ["orm"],
  },
];

/** Section directory to track title, for the lookup `navTracks` does. */
export const TRACK_OF = new Map(
  TRACKS.flatMap((track) => track.sections.map((slug) => [slug, track.title] as const)),
);
