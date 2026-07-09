# 正常执行优化(低内存机器会交互询问是否创建swap)
```
bash <(curl -fsSL https://raw.githubusercontent.com/snail46/linux-optimize/refs/heads/main/optimize-network.sh)
```

# 预览模式:只显示将要做的改动,不实际写入
```
bash <(curl -fsSL https://raw.githubusercontent.com/snail46/linux-optimize/refs/heads/main/optimize-network.sh) --dry-run
```

# 全自动模式:跳过交互确认,swap按磁盘检测结果自动创建
```
bash <(curl -fsSL https://raw.githubusercontent.com/snail46/linux-optimize/refs/heads/main/optimize-network.sh) --yes
```

# 还原优化(用最早备份恢复系统原始配置)
```
bash <(curl -fsSL https://raw.githubusercontent.com/snail46/linux-optimize/refs/heads/main/optimize-network.sh) --revert
```
