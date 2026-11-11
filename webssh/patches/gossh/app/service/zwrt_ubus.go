package service

import (
	"gossh/gin"
	"log/slog"
	"net/http"
)

// UbusAction 用于调用 ubus 并返回结果
func UbusAction(c *gin.Context) {
	// 请求参数结构体
	type ubusRequest struct {
		Service  string                 `form:"service"  json:"service"  binding:"required"`
		Method   string                 `form:"method"   json:"method"   binding:"required"`
		Params   map[string]interface{} `form:"params"   json:"params"`
		Tolerant bool                   `form:"tolerant" json:"tolerant"`
	}

	var req ubusRequest
	if err := c.ShouldBind(&req); err != nil {
		slog.Error("绑定数据错误", "err_msg", err.Error())
		c.JSON(http.StatusOK, gin.H{"code": 1, "msg": "输入数据不合法"})
		return
	}

	// 走设备兼容层：白名单方法在 B20 上会补参数重试 / 降级到 zwrt-datad，
	// 其余 service.method 行为与之前完全一致。
	result, err := CallUbusCompat(req.Service, req.Method, req.Params)
	if err != nil {
		slog.Error("Ubus 调用失败", "err_msg", err.Error())
		if req.Tolerant {
			// 可选兜底：调用方显式传 tolerant:true 时不再让整页失败。
			// 注意：前端 Empty.vue 目前不传该字段，因此这层默认不会生效。
			c.JSON(http.StatusOK, gin.H{
				"code":   0,
				"msg":    "ubus 调用失败，已按 tolerant 降级",
				"err":    err.Error(),
				"result": map[string]interface{}{},
			})
			return
		}
		c.JSON(http.StatusOK, gin.H{"code": 2, "msg": "ubus 调用失败", "err": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":   0,
		"msg":    "success",
		"result": result,
	})
}
