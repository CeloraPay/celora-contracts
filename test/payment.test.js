const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('PaymentGateway & PaymentEscrow - Native CELO tests', function () {
  let Gateway, gateway;
  let admin, payer, receiver, other;
  let amount, duration;
  let invoiceId, escrowAddress, escrow;

  beforeEach(async function () {
    [admin, payer, receiver, other] = await ethers.getSigners();
    amount = ethers.utils.parseEther('0.01');
    duration = 3600; // 1 hour

    // Deploy Gateway
    const GatewayFactory = await ethers.getContractFactory('PaymentGateway');
    gateway = await GatewayFactory.deploy();
    await gateway.deployed();

    // Register receiver
    await gateway.registerReceiver(receiver.address);
  });

  it('Should create a PaymentEscrow successfully', async function () {
    const tx = await gateway.createPayment(
      ethers.constants.AddressZero,
      receiver.address,
      ethers.constants.AddressZero,
      amount,
      duration,
    );
    const receipt = await tx.wait();

    // check event emitted
    const event = receipt.events.find((e) => e.event === 'PaymentCreated');
    expect(event).to.exist;

    invoiceId = event.args.invoiceId;
    escrowAddress = event.args.escrowAddress;

    // Get escrow contract
    const EscrowFactory = await ethers.getContractFactory('PaymentEscrow');
    escrow = EscrowFactory.attach(escrowAddress);

    // check initial state
    expect(await escrow.amount()).to.equal(amount);
    expect(await escrow.receiver()).to.equal(receiver.address);
    expect(await escrow.deposited()).to.equal(false);
  });

  it('Should deposit native CELO and finalize successfully', async function () {
    // Create Payment
    const tx = await gateway.createPayment(
      ethers.constants.AddressZero,
      receiver.address,
      ethers.constants.AddressZero,
      amount,
      duration,
    );
    const receipt = await tx.wait();
    const event = receipt.events.find((e) => e.event === 'PaymentCreated');
    invoiceId = event.args.invoiceId;
    escrowAddress = event.args.escrowAddress;
    const EscrowFactory = await ethers.getContractFactory('PaymentEscrow');
    escrow = EscrowFactory.attach(escrowAddress);

    // Deposit native
    await payer.sendTransaction({
      to: escrow.address,
      value: amount,
    });
    expect(await escrow.deposited()).to.equal(true);

    // Finalize
    const balanceReceiverBefore = await ethers.provider.getBalance(
      receiver.address,
    );
    const balanceGatewayBefore = await ethers.provider.getBalance(
      gateway.address,
    );

    await gateway.finalizePayment(invoiceId, false);

    const balanceReceiverAfter = await ethers.provider.getBalance(
      receiver.address,
    );
    const balanceGatewayAfter = await ethers.provider.getBalance(
      gateway.address,
    );

    // Receiver should get 95%, Gateway 5%
    const receiverGain = balanceReceiverAfter.sub(balanceReceiverBefore);
    const gatewayGain = balanceGatewayAfter.sub(balanceGatewayBefore);

    expect(receiverGain).to.equal(amount.mul(95).div(100));
    expect(gatewayGain).to.equal(amount.mul(5).div(100));
  });

  it('Should handle expired escrow correctly', async function () {
    // Create Payment
    const tx = await gateway.createPayment(
      ethers.constants.AddressZero,
      receiver.address,
      ethers.constants.AddressZero,
      amount,
      1, // 1 second duration
    );
    const receipt = await tx.wait();
    const event = receipt.events.find((e) => e.event === 'PaymentCreated');
    invoiceId = event.args.invoiceId;
    escrowAddress = event.args.escrowAddress;
    const EscrowFactory = await ethers.getContractFactory('PaymentEscrow');
    escrow = EscrowFactory.attach(escrowAddress);

    // Deposit native
    await payer.sendTransaction({
      to: escrow.address,
      value: amount,
    });

    // Wait for expiry
    await ethers.provider.send('evm_increaseTime', [2]);
    await ethers.provider.send('evm_mine', []);

    // Finalize expired
    const balancePayerBefore = await ethers.provider.getBalance(payer.address);
    const balanceGatewayBefore = await ethers.provider.getBalance(
      gateway.address,
    );

    await gateway.finalizePayment(invoiceId, false);

    const balancePayerAfter = await ethers.provider.getBalance(payer.address);
    const balanceGatewayAfter = await ethers.provider.getBalance(
      gateway.address,
    );

    // Payer should get 90%, Gateway 10%
    expect(balancePayerAfter.sub(balancePayerBefore)).to.equal(
      amount.mul(90).div(100),
    );
    expect(balanceGatewayAfter.sub(balanceGatewayBefore)).to.equal(
      amount.mul(10).div(100),
    );
  });

  it('Should distribute native rewards and allow claimReward', async function () {
    // Send CELO to gateway
    await admin.sendTransaction({
      to: gateway.address,
      value: ethers.utils.parseEther('1'),
    });

    // distribute 10%
    await gateway.distributeNativeReward(10);

    const pending = await gateway.pendingRewards(receiver.address);
    expect(pending).to.equal(ethers.utils.parseEther('0.1')); // 10% of 1 CELO

    // Claim reward
    const balanceBefore = await ethers.provider.getBalance(receiver.address);
    const tx = await gateway.connect(receiver).claimReward();
    const receipt = await tx.wait();
    const gasUsed = receipt.gasUsed.mul(receipt.effectiveGasPrice);

    const balanceAfter = await ethers.provider.getBalance(receiver.address);
    expect(balanceAfter.sub(balanceBefore).add(gasUsed)).to.equal(pending);
  });

  it('Should revert on double deposit', async function () {
    // Create Payment
    const tx = await gateway.createPayment(
      ethers.constants.AddressZero,
      receiver.address,
      ethers.constants.AddressZero,
      amount,
      duration,
    );
    const event = (await tx.wait()).events.find(
      (e) => e.event === 'PaymentCreated',
    );
    escrowAddress = event.args.escrowAddress;
    const EscrowFactory = await ethers.getContractFactory('PaymentEscrow');
    escrow = EscrowFactory.attach(escrowAddress);

    await payer.sendTransaction({ to: escrow.address, value: amount });

    await expect(
      payer.sendTransaction({ to: escrow.address, value: amount }),
    ).to.be.revertedWith('AlreadyDeposited');
  });

  it('Should revert on wrong deposit amount', async function () {
    const tx = await gateway.createPayment(
      ethers.constants.AddressZero,
      receiver.address,
      ethers.constants.AddressZero,
      amount,
      duration,
    );
    const event = (await tx.wait()).events.find(
      (e) => e.event === 'PaymentCreated',
    );
    escrowAddress = event.args.escrowAddress;
    const EscrowFactory = await ethers.getContractFactory('PaymentEscrow');
    escrow = EscrowFactory.attach(escrowAddress);

    await expect(
      payer.sendTransaction({
        to: escrow.address,
        value: ethers.utils.parseEther('0.001'),
      }),
    ).to.be.revertedWith('DepositNotExpected');
  });
});
