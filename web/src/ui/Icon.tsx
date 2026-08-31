import type { ReactNode } from 'react';

/**
 * Inline SVG icons using the exact Ionicons (outline) artwork rendered by the
 * mobile app via `@expo/vector-icons`. Kept dependency-free by embedding the
 * source paths directly. Elements marked `ionicon-fill-none` /
 * `ionicon-stroke-width` are styled in index.css so outline strokes and solid
 * fills render the same way Ionicons does.
 *
 * Source: ionicons@7.4.0, viewBox 0 0 512 512.
 */
export type IconName =
  | 'home'
  | 'calendar'
  | 'hammer'
  | 'document-text'
  | 'receipt'
  | 'people'
  | 'cash'
  | 'repeat'
  | 'pricetags'
  | 'settings';

const PATHS: Record<IconName, ReactNode> = {
  home: (
    <>
      <path
        d="M80 212v236a16 16 0 0016 16h96V328a24 24 0 0124-24h80a24 24 0 0124 24v136h96a16 16 0 0016-16V212"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M480 256L266.89 52c-5-5.28-16.69-5.34-21.78 0L32 256M400 179V64h-48v69"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  calendar: (
    <>
      <rect
        strokeLinejoin="round"
        x="48"
        y="80"
        width="416"
        height="384"
        rx="48"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <circle cx="296" cy="232" r="24" />
      <circle cx="376" cy="232" r="24" />
      <circle cx="296" cy="312" r="24" />
      <circle cx="376" cy="312" r="24" />
      <circle cx="136" cy="312" r="24" />
      <circle cx="216" cy="312" r="24" />
      <circle cx="136" cy="392" r="24" />
      <circle cx="216" cy="392" r="24" />
      <circle cx="296" cy="392" r="24" />
      <path
        strokeLinejoin="round"
        strokeLinecap="round"
        d="M128 48v32M384 48v32"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        strokeLinejoin="round"
        d="M464 160H48"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  hammer: (
    <path
      d="M277.42 247a24.68 24.68 0 00-4.08-5.47L255 223.44a21.63 21.63 0 00-6.56-4.57 20.93 20.93 0 00-23.28 4.27c-6.36 6.26-18 17.68-39 38.43C146 301.3 71.43 367.89 37.71 396.29a16 16 0 00-1.09 23.54l39 39.43a16.13 16.13 0 0023.67-.89c29.24-34.37 96.3-109 136-148.23 20.39-20.06 31.82-31.58 38.29-37.94a21.76 21.76 0 003.84-25.2zM478.43 201l-34.31-34a5.44 5.44 0 00-4-1.59 5.59 5.59 0 00-4 1.59h0a11.41 11.41 0 01-9.55 3.27c-4.48-.49-9.25-1.88-12.33-4.86-7-6.86 1.09-20.36-5.07-29a242.88 242.88 0 00-23.08-26.72c-7.06-7-34.81-33.47-81.55-52.53a123.79 123.79 0 00-47-9.24c-26.35 0-46.61 11.76-54 18.51-5.88 5.32-12 13.77-12 13.77a91.29 91.29 0 0110.81-3.2 79.53 79.53 0 0123.28-1.49C241.19 76.8 259.94 84.1 270 92c16.21 13 23.18 30.39 24.27 52.83.8 16.69-15.23 37.76-30.44 54.94a7.85 7.85 0 00.4 10.83l21.24 21.23a8 8 0 0011.14.1c13.93-13.51 31.09-28.47 40.82-34.46s17.58-7.68 21.35-8.09a35.71 35.71 0 0121.3 4.62 13.65 13.65 0 013.08 2.38c6.46 6.56 6.07 17.28-.5 23.74l-2 1.89a5.5 5.5 0 000 7.84l34.31 34a5.5 5.5 0 004 1.58 5.65 5.65 0 004-1.58L478.43 209a5.82 5.82 0 000-8z"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="ionicon-fill-none ionicon-stroke-width"
    />
  ),
  'document-text': (
    <>
      <path
        d="M416 221.25V416a48 48 0 01-48 48H144a48 48 0 01-48-48V96a48 48 0 0148-48h98.75a32 32 0 0122.62 9.37l141.26 141.26a32 32 0 019.37 22.62z"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M256 56v120a32 32 0 0032 32h120M176 288h160M176 368h160"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  receipt: (
    <>
      <path
        strokeLinejoin="round"
        d="M160 336V48l32 16 32-16 31.94 16 32.37-16L320 64l31.79-16 31.93 16L416 48l32.01 16L480 48v224"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M480 272v112a80 80 0 01-80 80h0a80 80 0 01-80-80v-48H48a15.86 15.86 0 00-16 16c0 64 6.74 112 80 112h288"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M224 144h192M288 224h128"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  people: (
    <>
      <path
        d="M402 168c-2.93 40.67-33.1 72-66 72s-63.12-31.32-66-72c-3-42.31 26.37-72 66-72s69 30.46 66 72z"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M336 304c-65.17 0-127.84 32.37-143.54 95.41-2.08 8.34 3.15 16.59 11.72 16.59h263.65c8.57 0 13.77-8.25 11.72-16.59C463.85 335.36 401.18 304 336 304z"
        strokeMiterlimit="10"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M200 185.94c-2.34 32.48-26.72 58.06-53 58.06s-50.7-25.57-53-58.06C91.61 152.15 115.34 128 147 128s55.39 24.77 53 57.94z"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M206 306c-18.05-8.27-37.93-11.45-59-11.45-52 0-102.1 25.85-114.65 76.2-1.65 6.66 2.53 13.25 9.37 13.25H154"
        strokeLinecap="round"
        strokeMiterlimit="10"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  cash: (
    <>
      <rect
        x="32"
        y="80"
        width="448"
        height="256"
        rx="16"
        ry="16"
        transform="rotate(180 256 208)"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M64 384h384M96 432h320"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <circle
        cx="256"
        cy="208"
        r="80"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M480 160a80 80 0 01-80-80M32 160a80 80 0 0080-80M480 256a80 80 0 00-80 80M32 256a80 80 0 0180 80"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  repeat: (
    <>
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M320 120l48 48-48 48"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M352 168H144a80.24 80.24 0 00-80 80v16M192 392l-48-48 48-48"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path
        d="M160 344h208a80.24 80.24 0 0080-80v-16"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  pricetags: (
    <>
      <path
        d="M403.29 32H280.36a14.46 14.46 0 00-10.2 4.2L24.4 281.9a28.85 28.85 0 000 40.7l117 117a28.86 28.86 0 0040.71 0L427.8 194a14.46 14.46 0 004.2-10.2v-123A28.66 28.66 0 00403.29 32z"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
      <path d="M352 144a32 32 0 1132-32 32 32 0 01-32 32z" />
      <path
        d="M230 480l262-262a13.81 13.81 0 004-10V80"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="ionicon-fill-none ionicon-stroke-width"
      />
    </>
  ),
  settings: (
    <path
      d="M262.29 192.31a64 64 0 1057.4 57.4 64.13 64.13 0 00-57.4-57.4zM416.39 256a154.34 154.34 0 01-1.53 20.79l45.21 35.46a10.81 10.81 0 012.45 13.75l-42.77 74a10.81 10.81 0 01-13.14 4.59l-44.9-18.08a16.11 16.11 0 00-15.17 1.75A164.48 164.48 0 01325 400.8a15.94 15.94 0 00-8.82 12.14l-6.73 47.89a11.08 11.08 0 01-10.68 9.17h-85.54a11.11 11.11 0 01-10.69-8.87l-6.72-47.82a16.07 16.07 0 00-9-12.22 155.3 155.3 0 01-21.46-12.57 16 16 0 00-15.11-1.71l-44.89 18.07a10.81 10.81 0 01-13.14-4.58l-42.77-74a10.8 10.8 0 012.45-13.75l38.21-30a16.05 16.05 0 006-14.08c-.36-4.17-.58-8.33-.58-12.5s.21-8.27.58-12.35a16 16 0 00-6.07-13.94l-38.19-30A10.81 10.81 0 0149.48 186l42.77-74a10.81 10.81 0 0113.14-4.59l44.9 18.08a16.11 16.11 0 0015.17-1.75A164.48 164.48 0 01187 111.2a15.94 15.94 0 008.82-12.14l6.73-47.89A11.08 11.08 0 01213.23 42h85.54a11.11 11.11 0 0110.69 8.87l6.72 47.82a16.07 16.07 0 009 12.22 155.3 155.3 0 0121.46 12.57 16 16 0 0015.11 1.71l44.89-18.07a10.81 10.81 0 0113.14 4.58l42.77 74a10.8 10.8 0 01-2.45 13.75l-38.21 30a16.05 16.05 0 00-6.05 14.08c.33 4.14.55 8.3.55 12.47z"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="ionicon-fill-none ionicon-stroke-width"
    />
  ),
};

type IconProps = {
  name: IconName;
  size?: number;
  className?: string;
  'aria-hidden'?: boolean;
};

export function Icon({ name, size = 20, className, ...rest }: IconProps) {
  return (
    <svg
      className={className ? `icon ${className}` : 'icon'}
      viewBox="0 0 512 512"
      width={size}
      height={size}
      role="img"
      aria-hidden={rest['aria-hidden'] ?? true}
    >
      {PATHS[name]}
    </svg>
  );
}
