window.DistrictPricing = {
  apply(price, quantity) {
    const qty = Math.max(1, Number(quantity || 1));
    const unit = Number(price?.unit_price || 0);
    const minimum = price?.wholesale_minimum == null ? null : Number(price.wholesale_minimum);
    const wholesale = price?.wholesale_price == null ? null : Number(price.wholesale_price);
    const isWholesale = minimum !== null && wholesale !== null && qty >= minimum;
    return {
      unitPrice: isWholesale ? wholesale : unit,
      isWholesale,
      minimum,
      subtotal: (isWholesale ? wholesale : unit) * qty,
    };
  },
  label(tier) {
    return ({ cpf: 'CPF', cnpj: 'CNPJ', alianca: 'Aliança', parceria: 'Parceria' })[tier] || tier;
  },
};
