db = db.getSiblingDB('testdb');

db.products.insertMany([
    { name: 'Widget A', price: 9.99, stock: 42 },
    { name: 'Widget B', price: 19.99, stock: 13 },
    { name: 'Gadget C', price: 49.99, stock: 7 }
]);
