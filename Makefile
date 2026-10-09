.PHONY: proj

# 生成 Edgely.xcodeproj（带不带设备实现包由 scripts/gen_proj.sh 检测）
proj:
	./scripts/gen_proj.sh
