import Foundation

/// An app Poki knows by name: its bundle ID, the icon Poki carries for it, and its names as the
/// iPhone shows them. The one list behind the app icons (`AppIconStore`), the home page's pills and
/// the message field's app capsules (`AppCapsule`).
struct KnownApp {
    let id: String
    /// `Poki/AppIcons/<icon>.png`, the App Store artwork Poki carries (AppIcons.md); nil when only
    /// the iPhone's own icon or the App Store's lookup can show it.
    let icon: String?
    let english: String
    let simplified: String
    let traditional: String
    /// Other names people write for it: an older name, a short one, the maker's English name.
    let aliases: [String]
    /// The bundle IDs of its other editions, which an iPhone may have instead (Bilibili's international one).
    let otherIDs: [String]

    init(_ id: String, icon: String?, _ english: String, _ simplified: String? = nil, _ traditional: String? = nil,
         aliases: [String] = [], otherIDs: [String] = []) {
        self.id = id
        self.otherIDs = otherIDs
        self.icon = icon
        self.english = english
        self.simplified = simplified ?? english
        self.traditional = traditional ?? simplified ?? english
        self.aliases = aliases
    }

    /// Its own bundle ID, then its other editions'.
    var ids: [String] { [id] + otherIDs }

    /// Every name that means this app, each once.
    var names: [String] {
        var out: [String] = []
        for name in [english, simplified, traditional] + aliases where !out.contains(name) { out.append(name) }
        return out
    }

    /// Its name on an iPhone in `language`.
    func name(in language: AppLanguage) -> String {
        switch language {
        case .english: english
        case .simplifiedChinese: simplified
        case .traditionalChinese: traditional
        }
    }
}

enum KnownApps {
    /// One identity lookup for app text, icons and the file passed to the widget.
    static func find(_ value: String) -> KnownApp? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return byID[key] ?? byName[key].flatMap { byID[$0.lowercased()] }
    }

    /// Apple's apps, the apps people in mainland China use every day, and the apps the English home
    /// page's pills name and their common neighbours. Icons fetched on Nov 11 to 13 2026 (AppIcons.md).
    static let all: [KnownApp] = apple + china + english

    private static let apple: [KnownApp] = [
        KnownApp("com.apple.MobileSMS", icon: "messages", "Messages", "信息", "訊息"),
        KnownApp("com.apple.mobilephone", icon: "phone", "Phone", "电话", "電話"),
        KnownApp("com.apple.mobilenotes", icon: "notes", "Notes", "备忘录", "備忘錄"),
        KnownApp("com.apple.reminders", icon: "reminders", "Reminders", "提醒事项", "提醒事項"),
        KnownApp("com.apple.mobilecal", icon: "calendar", "Calendar", "日历", "行事曆"),
        KnownApp("com.apple.Maps", icon: "maps", "Maps", "地图", "地圖"),
        KnownApp("com.apple.camera", icon: "camera", "Camera", "相机", "相機"),
        KnownApp("com.apple.mobileslideshow", icon: "photos", "Photos", "照片"),
        KnownApp("com.apple.mobilemail", icon: "mail", "Mail", "邮件", "郵件"),
        KnownApp("com.apple.mobilesafari", icon: "safari", "Safari", "Safari浏览器", "Safari瀏覽器",
                 aliases: ["Safari 浏览器", "Safari 瀏覽器"]),
        KnownApp("com.apple.weather", icon: "weather", "Weather", "天气", "天氣"),
        KnownApp("com.apple.mobiletimer", icon: "clock", "Clock", "时钟", "時鐘"),
        KnownApp("com.apple.calculator", icon: "calculator", "Calculator", "计算器", "計算機"),
        KnownApp("com.apple.Music", icon: "music", "Music", "音乐", "音樂"),
        KnownApp("com.apple.shortcuts", icon: "shortcuts", "Shortcuts", "快捷指令", "捷徑"),
        KnownApp("com.apple.DocumentsApp", icon: "files", "Files", "文件", "檔案"),
        KnownApp("com.apple.TestFlight", icon: "testflight", "TestFlight"),
        // No App Store listing, so no artwork to carry: only this iPhone's own icon can show them.
        KnownApp("com.apple.Preferences", icon: nil, "Settings", "设置", "設定"),
        KnownApp("com.apple.AppStore", icon: nil, "App Store"),
        KnownApp("com.apple.MobileAddressBook", icon: nil, "Contacts", "通讯录", "聯絡人"),
        KnownApp("com.apple.Health", icon: nil, "Health", "健康"),
        KnownApp("com.apple.Passbook", icon: nil, "Wallet", "钱包", "錢包"),
        KnownApp("com.apple.findmy", icon: nil, "Find My", "查找", "尋找"),
        KnownApp("com.apple.facetime", icon: nil, "FaceTime"),
        KnownApp("com.apple.Passwords", icon: nil, "Passwords", "密码", "密碼"),
        // On the App Store; fetched by the lookup on first use.
        KnownApp("com.apple.podcasts", icon: nil, "Podcasts", "播客", "Podcast"),
        KnownApp("com.apple.VoiceMemos", icon: nil, "Voice Memos", "语音备忘录", "語音備忘錄"),
        KnownApp("com.apple.Translate", icon: nil, "Translate", "翻译", "翻譯"),
        KnownApp("com.apple.freeform", icon: nil, "Freeform", "无边记", "無邊記"),
        KnownApp("com.apple.Fitness", icon: nil, "Fitness", "健身"),
        KnownApp("com.apple.stocks", icon: nil, "Stocks", "股市"),
        KnownApp("com.apple.Home", icon: nil, "Home", "家庭"),
    ]

    /// China store artwork.
    private static let china: [KnownApp] = [
        KnownApp("com.tencent.xin", icon: "wechat", "WeChat", "微信"),
        KnownApp("com.alipay.iphoneclient", icon: "alipay", "Alipay", "支付宝", "支付寶"),
        KnownApp("com.taobao.taobao4iphone", icon: "taobao", "Taobao", "淘宝", "淘寶"),
        KnownApp("com.360buy.jdmobile", icon: "jd", "JD", "京东", "京東"),
        KnownApp("com.xunmeng.pinduoduo", icon: "pinduoduo", "Pinduoduo", "拼多多"),
        KnownApp("com.meituan.imeituan", icon: "meituan", "Meituan", "美团", "美團"),
        KnownApp("com.meituan.itakeaway", icon: "meituan-waimai", "Meituan Waimai", "美团外卖", "美團外賣"),
        // The App Store lists Ele.me as 淘宝闪购 (Nov 2026); people still say 饿了么.
        KnownApp("me.ele.ios.eleme", icon: "eleme", "Ele.me", "饿了么", "餓了麼", aliases: ["淘宝闪购", "淘寶閃購"]),
        KnownApp("com.dianping.dpscope", icon: "dianping", "Dianping", "大众点评", "大眾點評"),
        KnownApp("com.xingin.discover", icon: "xiaohongshu", "Xiaohongshu", "小红书", "小紅書", aliases: ["RED", "rednote"]),
        KnownApp("com.ss.iphone.ugc.Aweme", icon: "douyin", "Douyin", "抖音"),
        KnownApp("com.jiangjia.gif", icon: "kuaishou", "Kuaishou", "快手"),
        KnownApp("tv.danmaku.bilianime", icon: "bilibili", "Bilibili", "哔哩哔哩", "嗶哩嗶哩", aliases: ["B站"],
                 otherIDs: ["com.bilibili.inter"]),
        KnownApp("com.sina.weibo", icon: "weibo", "Weibo", "微博"),
        KnownApp("com.zhihu.ios", icon: "zhihu", "Zhihu", "知乎"),
        KnownApp("com.taobao.fleamarket", icon: "xianyu", "Xianyu", "闲鱼", "閒魚"),
        KnownApp("com.autonavi.amap", icon: "amap", "Amap", "高德地图", "高德地圖"),
        KnownApp("com.baidu.map", icon: "baidu-maps", "Baidu Maps", "百度地图", "百度地圖"),
        KnownApp("com.xiaojukeji.didi", icon: "didi", "DiDi", "滴滴出行", aliases: ["滴滴"]),
        KnownApp("cn.12306.rails12306", icon: "rails12306", "Railway 12306", "铁路12306", "鐵路12306", aliases: ["12306", "Railway12306"]),
        KnownApp("ctrip.com", icon: "ctrip", "Trip.com", "携程旅行", "攜程旅行", aliases: ["携程", "攜程", "Ctrip"]),
        KnownApp("com.netease.cloudmusic", icon: "netease-music", "NetEase Cloud Music", "网易云音乐", "網易雲音樂"),
        KnownApp("com.tencent.QQMusic", icon: "qq-music", "QQ Music", "QQ音乐", "QQ音樂", aliases: ["QQ 音乐", "QQ 音樂"]),
        KnownApp("com.tencent.mqq", icon: "qq", "QQ"),
        KnownApp("com.laiwang.DingTalk", icon: "dingtalk", "DingTalk", "钉钉", "釘釘"),
        KnownApp("com.bytedance.ee.lark", icon: "feishu", "Feishu", "飞书", "飛書", aliases: ["Lark"]),
        KnownApp("com.tencent.ww", icon: "wecom", "WeCom", "企业微信", "企業微信"),
        KnownApp("com.baidu.BaiduMobile", icon: "baidu", "Baidu", "百度"),
        KnownApp("com.tencent.live4iphone", icon: "tencent-video", "Tencent Video", "腾讯视频", "騰訊視頻"),
        KnownApp("com.qiyi.iphone", icon: "iqiyi", "iQIYI", "爱奇艺", "愛奇藝"),
    ]

    /// US store artwork.
    private static let english: [KnownApp] = [
        KnownApp("com.tinyspeck.chatlyio", icon: "slack", "Slack"),
        KnownApp("com.ubercab.UberClient", icon: "uber", "Uber"),
        KnownApp("com.starbucks.mystarbucks", icon: "starbucks", "Starbucks", "星巴克"),
        KnownApp("com.burbn.instagram", icon: "instagram", "Instagram"),
        KnownApp("net.whatsapp.WhatsApp", icon: "whatsapp", "WhatsApp"),
        KnownApp("ph.telegra.Telegraph", icon: "telegram", "Telegram"),
        KnownApp("com.atebits.Tweetie2", icon: "x", "X"),
        KnownApp("com.google.ios.youtube", icon: "youtube", "YouTube"),
        KnownApp("com.google.chrome.ios", icon: "chrome", "Chrome", aliases: ["Google Chrome"]),
        KnownApp("com.spotify.client", icon: "spotify", "Spotify"),
        KnownApp("com.zhiliaoapp.musically", icon: "tiktok", "TikTok"),
        KnownApp("com.google.Gmail", icon: "gmail", "Gmail"),
        KnownApp("com.google.Maps", icon: "google-maps", "Google Maps", "Google 地图", "Google 地圖"),
        KnownApp("com.amazon.Amazon", icon: "amazon", "Amazon"),
        KnownApp("doordash.DoorDashConsumer", icon: "doordash", "DoorDash"),
        KnownApp("com.ubercab.UberEats", icon: "uber-eats", "Uber Eats"),
        KnownApp("com.zimride.instant", icon: "lyft", "Lyft"),
        KnownApp("com.airbnb.app", icon: "airbnb", "Airbnb"),
        KnownApp("com.netflix.Netflix", icon: "netflix", "Netflix"),
        KnownApp("com.facebook.Facebook", icon: "facebook", "Facebook"),
        KnownApp("com.facebook.Messenger", icon: "messenger", "Messenger"),
        KnownApp("com.linkedin.LinkedIn", icon: "linkedin", "LinkedIn"),
        KnownApp("com.reddit.Reddit", icon: "reddit", "Reddit"),
        KnownApp("com.hammerandchisel.discord", icon: "discord", "Discord"),
        KnownApp("us.zoom.videomeetings", icon: "zoom", "Zoom", aliases: ["Zoom Workplace"]),
        KnownApp("com.microsoft.skype.teams", icon: "teams", "Teams", aliases: ["Microsoft Teams"]),
        KnownApp("com.microsoft.Office.Outlook", icon: "outlook", "Outlook", aliases: ["Microsoft Outlook"]),
        KnownApp("com.yourcompany.PPClient", icon: "paypal", "PayPal"),
        KnownApp("com.instacart", icon: "instacart", "Instacart"),
        KnownApp("com.yelp.yelpiphone", icon: "yelp", "Yelp"),
        KnownApp("pinterest", icon: "pinterest", "Pinterest"),
        KnownApp("com.toyopagroup.picaboo", icon: "snapchat", "Snapchat"),
        KnownApp("com.burbn.barcelona", icon: "threads", "Threads"),
        KnownApp("com.contextoptional.OpenTable", icon: "opentable", "OpenTable"),
    ]

    /// By bundle ID, lower-cased.
    static let byID: [String: KnownApp] = Dictionary(
        all.flatMap { app in app.ids.map { ($0.lowercased(), app) } }, uniquingKeysWith: { first, _ in first })

    /// The bundle ID by each of an app's names, lower-cased.
    static let byName: [String: String] = Dictionary(
        all.flatMap { app in app.names.map { ($0.lowercased(), app.id) } }, uniquingKeysWith: { first, _ in first })
}
