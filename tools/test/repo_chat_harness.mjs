// Local verification harness for the repo-chat conversation logic.
// Mirrors the exact normalization and fast-path regexes from
// supabase/functions/repo-chat/index.ts. No dependencies are required.
//
// Run: node tools/test/repo_chat_harness.mjs
//
// When changing norm(), GREETING_RE, or SMALL_TALK_POOLS in repo-chat, mirror
// them here and keep the chatter regression battery below intact.

let pass = 0, fail = 0;
function check(name, cond, extra = "") {
  if (cond) {
    pass++;
    console.log(`ok   ${name}`);
  } else {
    fail++;
    console.log(`FAIL ${name}${extra ? " — " + extra : ""}`);
  }
}

function norm(s) {
  return s
    .toLowerCase()
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/'/g, "")
    .replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\uFE0F\u200D]/gu, " ")
    .replace(/(?:^|\s)(?:[:;=8]-?[()dDpP]|[xX]d|<3)(?=\s|$)/g, " ")
    .replace(/\b(he(ll|lo)l|heello|helo)\b/g, "hello")
    .replace(/\b(hwo|howw)\b/g, "how")
    .replace(/\b(yuo|uyo)\b/g, "you")
    .replace(/\b(tank|tahnk|thnak|thansk|thnks|tks|thx|thnx|tnx|tq)\b/g, "thanks")
    .replace(/\bthank(?:\s+(?:you|yuo|u))?\b/g, "thanks")
    .replace(/\bthanks\s+(?:you|yuo|u)\b/g, "thanks")
    .replace(/\b(pleasse|plesae|plese)\b/g, "please")
    .replace(/\b(hep|hepl|heelp|halp)\b/g, "help")
    .replace(/\b(whats|wat|whut|waht)\b/g, "what")
    .replace(/\bhw\b/g, "how")
    .replace(/\br\b/g, "are")
    .replace(/\bplz|pls\b/g, "please")
    .replace(/\bu\b/g, "you")
    .replace(/\bur\b/g, "your")
    .replace(/\bi\s+wnt\b/g, "i want")
    .replace(/\bhlw\b/g, "hello")
    .replace(/\bhru\b/g, "how are you")
    .replace(/\bthanks\s+(?:so|very)\s+much\b/g, "thanks")
    .replace(/\bthanks\s+a\s+(?:lot|million|ton|bunch)\b/g, "thanks")
    .replace(/\bthanks[,.]?\s+(?:sm|alot|bro|man|mate|buddy|guys|dear|sir|madam|admin|friend)\b/g, "thanks")
    .replace(/\b(?:many|so\s+much)\s+thanks\b/g, "thanks")
    .replace(/\b(?:got\s*it|ok|okay|alright|great|awesome|perfect|fine|good|nice|works)\s+thanks\b/g, "thanks")
    .replace(/\bthanks\s+bye\b/g, "bye")
    .replace(/\b(hi|hello|hey|selam|hallo)\s+(?:there|friend|bros?|guys|team|everyone|dear|all|folks|fam|aliob|admin)\b/g, "$1")
    .replace(/\bhow\s+are\s+you\s+(?:doing\s+)?(?:today|this\s+(?:morning|afternoon|evening|night))\b/g, "how are you")
    .replace(/\b(?:hows?|how\s+is|how\s+was)\s+(?:your|ur)\s+day\s+going\b/g, "hows your day")
    .replace(/\b(?:what|how)\s+about\s+you\b/g, "and you")
    .replace(/\bhow\s+about\s+yourself\b/g, "and you")
    .replace(/\byourself\b/g, "and you")
    .replace(/\s+/g, " ")
    .trim();
}

const CAPABILITIES_REPLY = "I'm the Aliob assistant. Here's what I can help with.";

const GREETING_RE =
  /^(hi|hii+|hello+|hay|hey+|hy|hallo|hiya|yo|selam|selamta|ሰላም|salam|hola|howdy|greetings|good\s+(morning|afternoon|evening|day)|whats?\s*up|what'?s\s*up|sup|how\s+(are|r)\s+(you|u)|how\s+are\s+you\s+doing|how\s+(are|is)\s+it\s+going|hows?\s+it\s+going|how'?s\s+it\s+going|nice\s+to\s+meet\s+you|good\s+to\s+see\s+you|good\s+(day|evening))[\s!.,?]*$/i;

const SMALL_TALK_POOLS = [
  {
    re: /^(how'?s?|how\s+is)\s*(it\s*going|your\s*day|are\s*(you|u))([\s!,.?]*(and\s*(you|u))?)$|^how\s*(are|was)\s*(your|ur|the)\s*day([\s!,.?]*)?$|^(whats?|what'?s)\s*up[\s!.,?]*$/,
    replies: ["I'm doing great, thanks for asking! How can I help?"],
  },
  {
    re: /\b(who\s*are\s*(you|u)|are\s*(you|u)\s*(a\s*)?(robot|bot|ai|human)|what\s*can\s*(you|u)\s*(do|help)|what\s*do\s*you\s*(do|know)|what\s+is\s+your\s+name|how\s+do\s+you\s+work|are\s+you\s+real|do\s+you\s+(?:sleep|eat|rest)|who\s+(?:made|created|built|programmed)\s+you|what\s+are\s+you\b|your\s*name)\b/,
    replies: [CAPABILITIES_REPLY],
  },
  {
    re: /^(thanks?|ty|appreciate\s*it|much\s+appreciated|appreciated|thanks?\s+again|no\s+worries|np|cheers|great|perfect|awesome|nice\s*one|well\s*done)[\s!,.]*$/,
    replies: ["You're very welcome! Anything else?"],
  },
  {
    re: /^(bye|bye\s*bye|goodbye|see\s*(you|ya)(\s+(tomorrow|soon|later|around|then))?|later|catch\s+(you|ya)\s+later|talk\s+to\s+you\s+later|ttyl|take\s+care|good\s*night|gn|good\s*day)[\s!,.]*$/,
    replies: ["Goodbye! Come back any time."],
  },
  {
    re: /^(?:im|i\s+am|i\s+m|am|feeling|its|it\s+is)?\s*(?:fine|good|great|okay|ok|well|alright|not\s+bad|pretty\s+good|very\s+good|doing\s+(?:good|great|fine|well|okay)|cant\s+complain|asleep|alive)[\s!.,?]*(?:and\s+(?:you|u))?[\b\s!.,?]*$/,
    replies: ["Glad to hear it! What can I help with?"],
  },
  {
    re: /^(and\s+(?:you|u)|wbu|hbu|you\?|u\?)[\s!.,?]*$/,
    replies: ["I'm doing great! What can I help you with?"],
  },
  {
    re: /^(ok|okay|okay\s+good|alright|cool|nice|hmm+|oh+i+see|okey|k|kk|got\s*it|i\s*see|understood|makes\s+sense|sounds\s+good|that\s+helps|nice\s+to\s+hear|noted|copy\s*that|roger|will\s+do|sure\s+thing|fine|good|yes|yeah|yep|yup|sure|no|nope|nah|true|right|exactly|absolutely|definitely|of\s+course)[\s!.,?]*$/,
    replies: ["Is there anything else I can help you with?"],
  },
];

function smallTalkReply(q) {
  for (const tier of SMALL_TALK_POOLS) {
    if (tier.re.test(q)) return tier.replies[0];
  }
  return null;
}

function warmReply(input) {
  const q = norm(input);
  if (GREETING_RE.test(q)) return "greeting reply";
  return smallTalkReply(q);
}

const ISSUE_RE =
  /\b(not\s*(responding|answering|picking)|no\s*response|isn'?t\s*(responding|answering)|is\s+not\s*(responding|answering)|unresponsive|ignored?|ghosted|silent|scammed?|ripped|disappeared|won'?t\s*(reply|answer|respond|deliver)|refuses?\s*to\s*(reply|answer|respond|deliver|refund)|stuck|no\s*(update|progress)|where\s+is\s*(my|the)\s*(order|money|refund|delivery)|order\s*(problem|issue)|payment\s*(problem|issue|failed)|money\s*(lost|stuck)|delivery\s*(problem|issue)|complain(t|)|report\s*(a|an|the)?\s*(seller|provider|driver|user|problem|issue))\b/i;
const APPEAL_RE =
  /\b(appeals?|banned?|unban|suspend(ed|sion)?|flagged|spam(?:my|mer|ming)?|report\s+(?:a\s+|an\s+|the\s+)?(?:spam|abuse|scam(?:mer)?)|wrongly\s+(?:banned|flagged|suspended)|my\s+(?:account|shop|store)\s+(?:was|is|got|has\s+been)\s+(?:banned|suspended|flagged|closed|blocked)|account\s+(?:banned|suspended|blocked))\b/i;

// Greetings remain whole-message matches after normalization.
for (const input of [
  "hi", "hello", "hii", "ሰላም", "selam", "how are you", "how are you doing",
  "how's it going", "hows it going", "what's up", "whats up", "good morning",
  "good evening", "hi there!", "hello :)", "hlw", "hi friend",
  "how are you today", "how are you doing today", "hru",
]) {
  check(`greeting: ${JSON.stringify(input)}`, warmReply(input) !== null);
}
check("greeting rejects mixed real question", warmReply("hi how do I recharge") === null);

// Regression battery: these previously fell through to cold retrieval.
for (const input of [
  "hi there!", "hello :)", "hlw", "hi friend", "how are you today",
  "how are you doing today", "how is your day going", "hru", "how about you",
  "and you", "thank you so much", "thanks a lot", "many thanks", "thanks sm",
  "great thanks", "got it thanks", "works thanks", "i see", "got it",
  "understood", "okay good", "nice to hear", "that helps", "makes sense",
  "sounds good", "bye bye", "tnx bye", "how do you work",
]) {
  check(`chatter warm: ${JSON.stringify(input)}`, warmReply(input) !== null);
}

// Natural self-report and return-question variants.
for (const input of [
  "I'm fine", "i am good", "doing great", "can't complain", "what about you",
  "how about yourself", "you?", "wbu",
]) {
  check(`self/return question warm: ${JSON.stringify(input)}`, warmReply(input) !== null);
}

// Typo tolerance remains intact.
check("typo: helo", warmReply("helo") !== null);
check("typo: hw r u", norm("hw r u") === "how are you");
check("typo: thank yuo", warmReply("thank yuo") !== null);
check("typo: tnx", warmReply("tnx") !== null);
check("typo: tank you", warmReply("tank you") !== null);

// Real questions must not be swallowed by the anchored chatter tiers.
for (const input of [
  "how do I recharge my wallet",
  "how can I track my order",
  "what are the subscription fees",
  "how do I appeal a ban",
  "where is my order",
  "how do I report a seller",
]) {
  check(`real question reaches retrieval: ${JSON.stringify(input)}`, warmReply(input) === null);
}

const cannedPatterns = /sign\s*up|register|recharge|wallet|fee|ride|order|appeal|track|report/;
check("canned fee question still detected", cannedPatterns.test(norm("ok how do I recharge")));
check("canned mixed question still detected", cannedPatterns.test(norm("thanks, now tell me about fees")));
check("issue detection", ISSUE_RE.test("seller not responding") && ISSUE_RE.test("where is my order"));
check("appeal detection", APPEAL_RE.test("I was flagged as spam") && APPEAL_RE.test("my account was banned"));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
