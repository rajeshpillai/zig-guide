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
    title: "Foundations",
    blurb: "The language and the library it ships with. Start here.",
    sections: ["getting-started", "language-basics", "standard-library", "data-structures"],
  },
  {
    title: "Groundwork",
    blurb: "What the machine is doing, from zero. No C and no prior systems work assumed.",
    // After Foundations rather than before it, which is a claim about the
    // common reader rather than about difficulty. Most people arriving here can
    // already program and want Zig; sending them through nine chapters on what
    // a byte is before they have compiled anything is the wrong first
    // impression, and they can reach this track the moment they want it.
    //
    // Separate from Foundations because it answers a different question.
    // Foundations teaches the language: what `*T` means and what the compiler
    // will not let you do with it. This teaches the machine the language is
    // describing: that an address is a number, that a type is an agreement
    // about how to read bytes, that a size is a choice with a cost.
    //
    // The reader who needs it first is served by `/paths/`, whose "New to
    // systems programming" route puts these chapters ahead of Getting Started.
    // A reading path is a curated route and is allowed to disagree with the
    // sidebar; that is the whole reason it exists.
    sections: ["systems-from-scratch"],
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
    title: "From Scratch",
    blurb: "Rebuild the tools you use every day, one program at a time, using nothing you did not write.",
    // A separate track rather than more Cookbook, because the pedagogy is
    // different. A recipe answers "how do I do X in Zig". These answer "what
    // is X, actually", and the answer is a complete program you could have
    // written yourself in 1975. The order is the one a from-scratch C course
    // takes, which is why `cat` comes before `wc` and `make` comes last: each
    // tool is allowed to assume the ones before it.
    // One section per phase of the sequence this follows. Phases land as they
    // are written rather than all at once, and a section listed here with no
    // chapters yet simply does not appear.
    sections: ["terminal", "unix-tools", "tiny-lang", "web-server"],
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
