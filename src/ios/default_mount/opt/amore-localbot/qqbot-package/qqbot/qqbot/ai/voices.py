"""豆包语音合成 2.0 官方音色清单。

音色 ID 必须以 ``_uranus_bigtts`` 结尾才属于 ``seed-tts-2.0`` 资源
（``_moon_bigtts`` / ``_mars_bigtts`` 那些是 1.0 音色，配上 2.0 资源会报
「resource ID is mismatched with speaker related resource」）。

清单来自官方音色列表文档，用于在面板里直接挑选，省得去控制台翻 ID。
"""

from __future__ import annotations

from typing import Any

#: 常用音色：(显示名, 音色ID)
VOICES_2_0: list[tuple[str, str]] = [
    ("Vivi 2.0（S2S主打·女）", "zh_female_vv_uranus_bigtts"),
    ("小何 2.0（S2S主打·女）", "zh_female_xiaohe_uranus_bigtts"),
    ("云舟 2.0（S2S主打·男）", "zh_male_m191_uranus_bigtts"),
    ("小天 2.0（S2S主打·男）", "zh_male_taocheng_uranus_bigtts"),
    ("爽快思思 2.0", "zh_female_shuangkuaisisi_uranus_bigtts"),
    ("知性灿灿 2.0", "zh_female_cancan_uranus_bigtts"),
    ("高冷御姐 2.0", "zh_female_gaolengyujie_uranus_bigtts"),
    ("邻家女孩 2.0", "zh_female_linjianvhai_uranus_bigtts"),
    ("邻家男孩 2.0", "zh_male_linjiananhai_uranus_bigtts"),
    ("温柔小雅 2.0", "zh_female_wenrouxiaoya_uranus_bigtts"),
    ("俏皮女声 2.0", "zh_female_qiaopinv_uranus_bigtts"),
    ("甜美桃子 2.0", "zh_female_tianmeitaozi_uranus_bigtts"),
    ("甜美小源 2.0", "zh_female_tianmeixiaoyuan_uranus_bigtts"),
    ("清新女声 2.0", "zh_female_qingxinnvsheng_uranus_bigtts"),
    ("知性女声 2.0", "zh_female_zhixingnv_uranus_bigtts"),
    ("亲切女声 2.0", "zh_female_qinqienv_uranus_bigtts"),
    ("贴心女声 2.0", "zh_female_tiexinnvsheng_uranus_bigtts"),
    ("开朗姐姐 2.0", "zh_female_kailangjiejie_uranus_bigtts"),
    ("温柔淑女 2.0", "zh_female_wenroushunv_uranus_bigtts"),
    ("魅力女友 2.0", "zh_female_meilinvyou_uranus_bigtts"),
    ("柔美女友 2.0", "zh_female_roumeinvyou_uranus_bigtts"),
    ("古风少御 2.0", "zh_female_gufengshaoyu_uranus_bigtts"),
    ("萌丫头 2.0", "zh_female_mengyatou_uranus_bigtts"),
    ("撒娇学妹 2.0", "zh_female_sajiaoxuemei_uranus_bigtts"),
    ("温暖阿虎 2.0", "zh_male_wennuanahu_uranus_bigtts"),
    ("渊博小叔 2.0", "zh_male_yuanboxiaoshu_uranus_bigtts"),
    ("阳光青年 2.0", "zh_male_yangguangqingnian_uranus_bigtts"),
    ("儒雅青年 2.0", "zh_male_ruyaqingnian_uranus_bigtts"),
    ("儒雅逸辰 2.0", "zh_male_ruyayichen_uranus_bigtts"),
    ("活力小哥 2.0", "zh_male_huolixiaoge_uranus_bigtts"),
    ("开朗学长 2.0", "zh_male_kailangxuezhang_uranus_bigtts"),
    ("开朗弟弟 2.0", "zh_male_kailangdidi_uranus_bigtts"),
    ("反卷青年 2.0", "zh_male_fanjuanqingnian_uranus_bigtts"),
    ("清爽男大 2.0", "zh_male_qingshuangnanda_uranus_bigtts"),
    ("傲娇霸总 2.0", "zh_male_aojiaobazong_uranus_bigtts"),
    ("解说小明 2.0", "zh_male_jieshuoxiaoming_uranus_bigtts"),
    ("深夜播客 2.0", "zh_male_shenyeboke_uranus_bigtts"),
    ("暖阳女声 2.0（客服）", "zh_female_kefunvsheng_uranus_bigtts"),
    ("Tina老师 2.0（教育）", "zh_female_yingyujiaoxue_uranus_bigtts"),
    ("儿童绘本 2.0", "zh_female_xiaoxue_uranus_bigtts"),
    ("唐僧 2.0（角色）", "zh_male_tangseng_uranus_bigtts"),
    ("猪八戒 2.0（角色）", "zh_male_zhubajie_uranus_bigtts"),
    ("猴哥 2.0（角色）", "zh_male_sunwukong_uranus_bigtts"),
    ("樱桃丸子 2.0（角色）", "zh_female_yingtaowanzi_uranus_bigtts"),
    ("熊二 2.0（角色）", "zh_male_xionger_uranus_bigtts"),
    ("Tim（英文·男）", "en_male_tim_uranus_bigtts"),
    ("Dacey（英文·女）", "en_female_dacey_uranus_bigtts"),
    ("Stokie（英文·女）", "en_female_stokie_uranus_bigtts"),
]

#: 控制台音色库地址
CONSOLE_URL = "https://console.volcengine.com/speech/new/voices?projectName=default"


def list_voices() -> list[dict[str, Any]]:
    return [{"name": name, "id": vid} for name, vid in VOICES_2_0]


def candidate_ids() -> list[str]:
    """用于自动探测的候选音色（按常用度排序）。"""
    return [vid for _name, vid in VOICES_2_0]