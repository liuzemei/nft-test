# digital-marketplace
用智能合约构建的 nft 市场

> 参考文档：
> [https://learnblockchain.cn/article/2799](https://learnblockchain.cn/article/2799)

## 开发环境
1. 安装依赖
```shell
npm install
```

2. 启动以太坊本环境
```shell
npx hardhat node
```

3. 在根目录下添加 `.sercret` 并把第二步生成的私钥，随机添加到文件中
如：
`.sercert`
```
ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

4. 部署智能合约
```shell
npx hardhat run scripts/deploy.js --network localhost
```
并将生成的 合约地址替换 `config.js` 中的地址（如果是一样的请忽略...）

5. 启动前端
```shell
npm run dev
```

6. 成功运行...