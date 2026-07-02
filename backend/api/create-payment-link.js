const Stripe = require('stripe');

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { amount, invoiceNumber, description, stripeKey } = req.body;

  if (!stripeKey) return res.status(400).json({ error: 'Stripe key required' });
  if (!amount || amount <= 0) return res.status(400).json({ error: 'Amount must be greater than 0' });

  try {
    const stripe = new Stripe(stripeKey, { apiVersion: '2023-10-16' });

    const product = await stripe.products.create({
      name: invoiceNumber ? `Invoice ${invoiceNumber}` : 'Invoice Payment',
      ...(description ? { description } : {}),
    });

    const price = await stripe.prices.create({
      currency: 'usd',
      unit_amount: Math.round(amount * 100),
      product: product.id,
    });

    const paymentLink = await stripe.paymentLinks.create({
      line_items: [{ price: price.id, quantity: 1 }],
      after_completion: {
        type: 'hosted_confirmation',
        hosted_confirmation: {
          custom_message: 'Payment received. Thank you for your business!',
        },
      },
    });

    res.status(200).json({ url: paymentLink.url });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
