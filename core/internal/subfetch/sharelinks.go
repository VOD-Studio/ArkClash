package subfetch

import (
	"bufio"
	"bytes"
	"errors"
	"io"

	"github.com/VOD-Studio/ArkClash/core/internal/proxylink"
)

// 判断格式只看开头这么多字节，Clash YAML 不必整段读入内存。
const shareLinkPeek = 4096

// ShareLinkBody 把 Base64 或纯文本的分享链接订阅转成 Clash 配置（#129）；其他内容原样透传。
// 转换失败时也原样返回，交给 UI 的配置检查报 not_clash。
func ShareLinkBody(body io.Reader, limit int64) (io.Reader, error) {
	buffered := bufio.NewReaderSize(body, shareLinkPeek)
	head, err := buffered.Peek(shareLinkPeek)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if !proxylink.LooksLikeShareLinks(head) {
		return buffered, nil
	}
	data, err := io.ReadAll(io.LimitReader(buffered, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("response too large")
	}
	if profile, ok := proxylink.SubscriptionProfile(data); ok {
		return bytes.NewReader(profile), nil
	}
	return bytes.NewReader(data), nil
}
