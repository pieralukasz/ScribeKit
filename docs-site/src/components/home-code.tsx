"use client";

import {
  DynamicCodeBlock,
  type DynamicCodeblockProps,
} from "fumadocs-ui/components/dynamic-codeblock";

type Options = NonNullable<DynamicCodeblockProps["options"]>;
type Transformer = NonNullable<Options["transformers"]>[number];

/**
 * Home page code block. Each line gets its leading indent as `--indent`, so on
 * phones (see global.css) long lines can wrap with a hanging indent instead of
 * scrolling sideways. Desktop rendering is unchanged.
 */
export function HomeCode({ code, lang }: { code: string; lang: string }) {
  const lines = code.split("\n");
  const hangingIndent: Transformer = {
    name: "home-hanging-indent",
    line(node, line) {
      const indent = /^ */.exec(lines[line - 1] ?? "")?.[0].length ?? 0;
      node.properties.style = `--indent: ${indent}ch`;
    },
  };

  return (
    <div className="home-code">
      <DynamicCodeBlock
        lang={lang}
        code={code}
        options={{
          themes: { light: "github-light", dark: "github-dark" },
          transformers: [hangingIndent],
        }}
      />
    </div>
  );
}
