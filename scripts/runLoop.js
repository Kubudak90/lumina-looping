main()

async function main(){
    const [address1, address2, address3] = await ethers.getSigners();

    const owner = address3;

    const swapper = "0x85aA63EB2ab9BaAA74eAd7e7f82A571d74901853" //hyperswap
    const pool = "0x1e85CCDf0D098a9f55b82F3E35013Eda235C8BD8" //lighterEvm testnet deployment

    const Looping = await ethers.getContractFactory("Looping");
    const looping = await Looping.deploy(
        [pool],
        [swapper],
        owner.address
    );
    // const looping = await ethers.getContractAt("Looping", "0xa1625001247DD1525a98c4cDb3dD9Ec1f55F1abd")
    console.log(`looping deployed to ${looping.target}`)

    const debtAsset = "0xe0bdd7e8b7bf5b15dcDA6103FCbBA82a460ae2C7" //WETH
    const yieldAsset = "0x453b63484b11bbF0b61fC7E854f8DAC7bdE7d458" //mBTC
    const hYieldToken = "0xde72990638db12f8AA4cd9406bA6c648153A5cEA"
    const debtAssetVariableDebtToken = "0xE5C5E18723991AF5D2a640f6C9667D48741429E6" //WETHVariableDebt
    const initialAmount = (0.1 * Math.pow(10, 18)).toString() //ETH
    const flashloanAmount = (0.2 * Math.pow(10, 18)).toString() //ETH
    const minAmountOut = 0;

    const debtInstance = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", debtAsset)
    const debtVariableDebtInstance = await ethers.getContractAt("IDebtToken", debtAssetVariableDebtToken)
    const hYieldInstance = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", hYieldToken)

    await debtVariableDebtInstance.connect(owner).approveDelegation(looping.target, "9999999999999999999999999999999999999999999999999999999999999999999999999999")
    await debtInstance.connect(owner).approve(looping.target, initialAmount)
    await hYieldInstance.connect(owner).approve(looping.target, "9999999999999999999999999999999999999999999999999999999999999999")
    console.log(`approved tokens`)

    console.log(await looping.connect(owner).openPosition(
        pool,
        swapper,
        debtAsset,
        yieldAsset,
        initialAmount,
        flashloanAmount,
        minAmountOut,
        [debtAsset, yieldAsset]
    ))
    console.log(`leveraged position opened`)

    //ltv: 0.75, btc = 90k, eth = 3.5k
    //initial amount: 0.1 ETH = 350 usd
    //flashloan amount: 0.4 ETH = 1400 usd

    //swap flashloan to BTC = 0.015555555 btc and supply it
    //borrow 0.015555555 btc * 90,000 usd * 0.75 tlv = 1050 usd worth of eth = 0.3 ETH
    //balance = 0.3 + 0.1 = 0.4 => repay flashloan
    //aave fee = 0.05%

    //max position ignoring fees: 1/(1-ltv) * initialAmount
    //fee: 1/(1-ltv) * initialAmount * 0.0005
    //max position from initial amount: 1/(1-ltv) * (initialAmount - fee)

    //0.1 ETH initial amount = 0.3992 ETH flashloanAmount

    // const withdrawAmount = (0.005 * Math.pow(10, 8)).toString()
    // console.log(await looping.connect(owner).closePosition(
    //     pool,
    //     swapper,
    //     debtAsset,
    //     yieldAsset,
    //     initialAmount,
    //     flashloanAmount,
    //     minAmountOut,
    //     [yieldAsset, debtAsset],
    //     withdrawAmount
    // ))
    // console.log(`leveraged position reduced`)
}