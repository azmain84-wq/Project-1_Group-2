
-- Case 1: Missed the Deadline
-- Find orders required earlier than they shipped, or overdue + still unshipped.
SELECT 
    c.CustomerCompanyName,   -- who placed the order
    o.OrderId,               -- order identifier
    o.OrderDate,             -- when the order was entered
    o.RequiredDate,          -- requested-by date
    o.ShipToDate,            -- actual ship date (can be NULL)
    CASE 
        WHEN o.ShipToDate IS NULL AND o.RequiredDate < GETDATE() THEN 'OVERDUE & NOT SHIPPED' -- past due, no ship
        WHEN o.ShipToDate > o.RequiredDate THEN 'SHIPPED LATE'                                -- shipped after required date
        ELSE 'OK'                                                                             -- everything else
    END AS StatusFlag         -- quick status tag for the row
FROM Sales.[Order] AS o        -- order header
JOIN Sales.Customer AS c       -- customer master
  ON c.CustomerId = o.CustomerId  -- link order to the customer
WHERE 
      (o.ShipToDate IS NULL AND o.RequiredDate < GETDATE())       -- overdue & still not shipped
   OR (o.ShipToDate IS NOT NULL AND o.ShipToDate > o.RequiredDate) -- shipped, but late
ORDER BY o.RequiredDate, o.ShipToDate;   -- show most urgent stuff first

-- Case 2: Catalog vs Reality
-- Order lines where the charged price is off by >= 20% from current catalog price.
SELECT 
    od.OrderId,                                      -- which order the line belongs to
    p.ProductId,                                     -- product key
    p.ProductName,                                   -- product name for readability
    p.UnitPrice       AS CatalogPrice,               -- price in the product table (current)
    od.UnitPrice      AS ChargedPrice,               -- price actually charged on the order line
    CAST((od.UnitPrice - p.UnitPrice) / NULLIF(p.UnitPrice,0.0) AS decimal(6,3)) AS PctDiff -- percent difference
FROM Sales.OrderDetail AS od                         -- line items
JOIN Production.Product AS p                         -- product catalog
  ON p.ProductId = od.ProductId                      -- match line item to product
WHERE ABS(od.UnitPrice - p.UnitPrice) >= 0.20 * p.UnitPrice  -- deviation >= 20%
ORDER BY ABS(od.UnitPrice - p.UnitPrice) DESC;       -- biggest mismatches first

-- Case 3: The Shared Doorstep
-- Different customers shipping to the exact same address (possible reshipper/fraud).
SELECT 
    o.ShipToAddress,                                            -- street
    o.ShipToPostalCode,                                         -- postal/zip
    o.ShipToCity,                                               -- city
    o.ShipToCountry,                                            -- country
    COUNT(DISTINCT o.CustomerId) AS DistinctCustomers,          -- how many unique customers ship here
    STRING_AGG(c.CustomerCompanyName, '; ') AS CustomersAtAddress -- list of those companies
FROM Sales.[Order] AS o                                         -- orders
JOIN Sales.Customer AS c                                        -- customers
  ON c.CustomerId = o.CustomerId                                -- link order->customer
WHERE COALESCE(o.ShipToAddress,'') <> ''                        -- ignore blank addresses
GROUP BY o.ShipToAddress, o.ShipToPostalCode, o.ShipToCity, o.ShipToCountry  -- group per full address
HAVING COUNT(DISTINCT o.CustomerId) > 1                         -- only addresses used by multiple customers
ORDER BY DistinctCustomers DESC, o.ShipToCountry, o.ShipToCity; -- busiest shared addresses first

-- Case 4: One-line Splurges
-- Orders with exactly one line and a big total (> $500).
WITH OrderFacts AS (
  SELECT 
      od.OrderId,                                                     -- order key
      COUNT(*) AS LineCount,                                          -- how many lines in that order
      -- Assuming DiscountedLineAmount is a fraction like 0.10 (10% off). If it's an absolute amount, adjust.
      SUM(od.UnitPrice * od.Quantity * (1 - od.DiscountedLineAmount)) AS ItemsTotal -- extended $ after discount
  FROM Sales.OrderDetail AS od                                        -- all order lines
  GROUP BY od.OrderId                                                 -- per-order rollup
)
SELECT 
    ofx.OrderId,                 -- order id
    ofx.ItemsTotal,              -- computed extended total
    c.CustomerCompanyName,       -- who bought it
    o.OrderDate                  -- when it happened
FROM OrderFacts AS ofx
JOIN Sales.[Order] AS o
  ON o.OrderId = ofx.OrderId     -- bring in header fields
JOIN Sales.Customer AS c
  ON c.CustomerId = o.CustomerId -- bring in customer name
WHERE ofx.LineCount = 1          -- single-line orders only
  AND ofx.ItemsTotal > 500       -- “splurge” threshold
ORDER BY ofx.ItemsTotal DESC;    -- biggest splurges first

-- Case 5: The Loner Product
-- Products that show up alone on the order >= 80% of the time (and have at least 5 appearances).
WITH OrderLineCounts AS (
  SELECT 
      od.OrderId, 
      COUNT(DISTINCT od.ProductId) AS DistinctProducts  -- how many different products on that order
  FROM Sales.OrderDetail AS od
  GROUP BY od.OrderId
),
ProductAppearances AS (
  SELECT 
      od.ProductId,                                                -- product key
      COUNT(*) AS TimesAppeared,                                   -- total lines this product appears on
      SUM(CASE WHEN olc.DistinctProducts = 1 THEN 1 ELSE 0 END) AS TimesAlone -- lines where it was the only product
  FROM Sales.OrderDetail AS od
  JOIN OrderLineCounts AS olc
    ON olc.OrderId = od.OrderId                                    -- join to know the per-order product count
  GROUP BY od.ProductId
)
SELECT 
    p.ProductId,                                                   -- product id
    p.ProductName,                                                 -- name for readability
    pa.TimesAppeared,                                              -- total appearances
    pa.TimesAlone,                                                 -- how often alone
    CAST(pa.TimesAlone * 1.0 / NULLIF(pa.TimesAppeared,0) AS decimal(5,2)) AS AloneRatio -- share of solo appearances
FROM ProductAppearances AS pa
JOIN Production.Product AS p
  ON p.ProductId = pa.ProductId                                    -- get product names
WHERE pa.TimesAppeared >= 5                                        -- avoid small-sample noise
  AND pa.TimesAlone * 1.0 / pa.TimesAppeared >= 0.80               -- at least 80% solo
ORDER BY AloneRatio DESC, pa.TimesAppeared DESC;                    -- most “solo” first, break ties by volume

-- Case 6: Supplier Lock-In
-- Customers who get >= 80% of their spend from a single supplier.
WITH LineTotals AS (
  SELECT 
      o.CustomerId,                                                -- who bought it
      p.SupplierId,                                                -- which supplier provided the product
      -- Same assumption as above: DiscountedLineAmount is a fraction (0–1). Tweak if it's absolute $.
      SUM(od.UnitPrice * od.Quantity * (1 - od.DiscountedLineAmount)) AS Spend -- extended spend per supplier
  FROM Sales.[Order] AS o
  JOIN Sales.OrderDetail AS od ON od.OrderId = o.OrderId           -- lines for each order
  JOIN Production.Product  AS p  ON p.ProductId = od.ProductId     -- map line to supplier via product
  GROUP BY o.CustomerId, p.SupplierId
),
CustTotals AS (
  SELECT 
      CustomerId, 
      SUM(Spend) AS TotalSpend                                     -- total customer spend across all suppliers
  FROM LineTotals
  GROUP BY CustomerId
),
ShareBySupplier AS (
  SELECT 
      lt.CustomerId,                                               -- customer
      lt.SupplierId,                                               -- supplier
      lt.Spend,                                                    -- spend with that supplier
      ct.TotalSpend,                                               -- customer's total spend
      CAST(lt.Spend / NULLIF(ct.TotalSpend,0) AS decimal(6,3)) AS SpendShare -- supplier share of customer spend
  FROM LineTotals lt
  JOIN CustTotals ct ON ct.CustomerId = lt.CustomerId              -- add total for denominator
)
SELECT 
    c.CustomerCompanyName,                                         -- customer name
    sup.SupplierId,                                                -- supplier id
    sup.SupplierCompanyName AS SupplierName,                       -- supplier name
    sb.Spend,                                                      -- $ to this supplier
    sb.TotalSpend,                                                 -- total $
    sb.SpendShare                                                  -- share (0–1)
FROM ShareBySupplier AS sb
JOIN Sales.Customer        AS c   ON c.CustomerId   = sb.CustomerId -- label the customer
JOIN Production.Supplier   AS sup ON sup.SupplierId = sb.SupplierId -- label the supplier
WHERE sb.SpendShare >= 0.80                                       -- lock-in threshold
ORDER BY sb.SpendShare DESC, sb.TotalSpend DESC;                   -- strongest lock-in first

-- Case 7: Not my home!
-- Orders shipped to a different country than the customer’s home country.
SELECT 
    c.CustomerCompanyName,          -- customer
    o.OrderId,                      -- order id
    c.CustomerCountry   AS CustomerHomeCountry,  -- customer’s country on file
    o.ShipToCountry     AS ShipDestinationCountry, -- ship-to country
    o.OrderDate                         -- when the order was placed
FROM Sales.[Order] AS o
JOIN Sales.Customer AS c
  ON c.CustomerId = o.CustomerId      -- link order to customer
WHERE COALESCE(c.CustomerCountry,'') <> COALESCE(o.ShipToCountry,'')  -- country mismatch -- had to use ai to find out mismatch
ORDER BY o.OrderDate DESC;            -- newest first
